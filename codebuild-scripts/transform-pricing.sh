#!/bin/bash
set -euo pipefail

echo "=== Transformation Script: Clone and Transform Pricing MCP Server ==="

# Clone upstream repository, pinned to a known-good commit.
# Upstream HEAD breaks these transforms: awslabs/mcp 1ea49904 (billing) and
# 13b13095 (pricing). 8ddc0294 is the last commit before either break.
# Override with MCP_COMMIT=<sha> if you deliberately move to a newer upstream.
MCP_COMMIT="${MCP_COMMIT:-8ddc029465d25cb043f810310a98ecbd639e9ca2}"
echo "Fetching upstream MCP repository at ${MCP_COMMIT}..."
git init -q mcp
git -C mcp remote add origin https://github.com/awslabs/mcp.git
git -C mcp fetch -q --depth 1 origin "$MCP_COMMIT"
git -C mcp checkout -q FETCH_HEAD
cd mcp/src/aws-pricing-mcp-server

SERVER_FILE="awslabs/aws_pricing_mcp_server/server.py"

# Transform server.py
# The pricing server uses mcp.server.fastmcp (mcp SDK) which has a different API
# than the fastmcp package used by billing. We patch the import to use the fastmcp
# package instead, so both servers work identically.
echo "Transforming server.py..."

python3 -c "
import re

with open('$SERVER_FILE', 'r') as f:
    content = f.read()

# 1. Replace mcp SDK import with fastmcp package import
old_import = 'from mcp.server.fastmcp import Context, FastMCP'
new_import = 'from fastmcp import FastMCP, Context'
if old_import in content:
    content = content.replace(old_import, new_import)
    print('Import patched: mcp.server.fastmcp -> fastmcp')
else:
    print('WARNING: Expected import not found, checking alternatives...')
    if 'from mcp.server.fastmcp import' in content:
        content = re.sub(r'from mcp\.server\.fastmcp import.*', new_import, content)
        print('Import patched via regex')
    else:
        print('ERROR: Could not find mcp.server.fastmcp import')
        exit(1)

# 2. Remove 'dependencies' kwarg from FastMCP constructor (not supported by fastmcp package)
content = re.sub(r'\\s*dependencies=\\[.*?\\],?\\n?', '\\n', content, flags=re.DOTALL)
print('Removed dependencies kwarg from FastMCP constructor')

# 3. No other constructor changes needed - fastmcp package accepts params in run()
print('FastMCP constructor: patched for fastmcp compatibility')

# 4. Fix get_pricing tool schema: replace Pydantic model types with plain types
# The AgentCore Gateway does not support \$ref in JSON schemas.
# PricingFilter and OutputOptions Pydantic models cause \$ref in the generated schema.
# Replace their type annotations with plain dict/list types.
content = re.sub(
    r'filters:\\s*Optional\\[List\\[PricingFilter\\]\\]',
    'filters: Optional[List[dict]]',
    content
)
content = re.sub(
    r'output_options:\\s*Optional\\[OutputOptions\\]',
    'output_options: Optional[dict]',
    content
)
print('Patched get_pricing type annotations to avoid \$ref in schema')

# 4b. Fix model_dump() calls - filters are now plain dicts, not Pydantic models
content = content.replace(
    'api_filters.extend([f.model_dump(by_alias=True) for f in filters])',
    'api_filters.extend([f if isinstance(f, dict) else f.model_dump(by_alias=True) for f in filters])'
)
print('Patched model_dump calls for dict compatibility')

# 5. Replace main() function - same approach as billing server
old_main = '''def main():
    \"\"\"Run the MCP server with CLI argument support.\"\"\"
    mcp.run()'''

new_main = '''def main():
    \"\"\"Run the MCP server with streamable-http transport.\"\"\"
    mcp.run(transport='streamable-http', host='0.0.0.0', port=8000, stateless_http=True)'''

if old_main in content:
    content = content.replace(old_main, new_main)
    print('main() function patched')
else:
    print('ERROR: Could not find expected main() function pattern')
    match = re.search(r'def main\(\).*?(?=\ndef |\Z)', content, re.DOTALL)
    if match:
        print(f'Found main(): {match.group(0)[:200]}...')
    exit(1)

with open('$SERVER_FILE', 'w') as f:
    f.write(content)

print('server.py transformation complete')
"

# Validate transformation
grep -q 'streamable-http' "$SERVER_FILE" || { echo "ERROR: streamable-http not found in server.py"; exit 1; }
grep -q 'port=8000' "$SERVER_FILE" || { echo "ERROR: port=8000 not found in server.py"; exit 1; }
grep -q 'from fastmcp import' "$SERVER_FILE" || { echo "ERROR: fastmcp import not found in server.py"; exit 1; }
echo "server.py transformation verified."

# Step 4c: Insert dict-to-model conversion code inside get_pricing function
# This must be done outside the python3 -c block to avoid bash escaping issues
python3 << 'PYEOF'
with open("awslabs/aws_pricing_mcp_server/server.py", "r") as f:
    content = f.read()

old_line = "    logger.info(f'Getting pricing for {service_code} in {region}')"
new_block = """    # Convert dict inputs to Pydantic models for internal use
    from awslabs.aws_pricing_mcp_server.models import OutputOptions as _OutputOptions, PricingFilter as _PricingFilter
    if output_options is not None and isinstance(output_options, dict):
        output_options = _OutputOptions(**output_options)
    if filters is not None:
        filters = [_PricingFilter(**f) if isinstance(f, dict) else f for f in filters]
    logger.info(f'Getting pricing for {service_code} in {region}')"""

content = content.replace(old_line, new_block, 1)

with open("awslabs/aws_pricing_mcp_server/server.py", "w") as f:
    f.write(content)
print("Added dict-to-model conversion inside get_pricing")
PYEOF

# Add fastmcp dependency to pyproject.toml and regenerate lockfile
echo "Adding fastmcp dependency..."
python3 -c "
with open('pyproject.toml', 'r') as f:
    content = f.read()

import re
content = re.sub(
    r'(dependencies\s*=\s*\[)',
    r'\1\n    \"fastmcp>=2.0.0,<3.0.0\",',
    content,
    count=1
)

with open('pyproject.toml', 'w') as f:
    f.write(content)
print('fastmcp dependency added to pyproject.toml')
"
grep -q 'fastmcp' pyproject.toml || { echo "ERROR: fastmcp not in pyproject.toml"; exit 1; }
# Install uv and regenerate lockfile with the new dependency
echo "Regenerating uv.lock with fastmcp dependency..."
pip3 install uv --quiet 2>/dev/null || python3 -m pip install uv --quiet
uv lock --python 3.13
echo "pyproject.toml transformation verified, lockfile regenerated."

# Disable UV_FROZEN in Dockerfile and remove --frozen from uv sync
echo "Disabling UV_FROZEN and --frozen in Dockerfile..."
sed -i 's/UV_FROZEN=1/UV_FROZEN=0/g' Dockerfile
sed -i '/ENV UV_FROZEN/d' Dockerfile
sed -i 's/ --frozen//g' Dockerfile
echo "UV_FROZEN and --frozen handling complete."
# Verify
if grep -q 'frozen' Dockerfile; then
    echo "WARNING: frozen still in Dockerfile:"
    grep 'frozen' Dockerfile
else
    echo "Verified: --frozen removed from Dockerfile"
fi

# Transform Dockerfile: add EXPOSE and update entrypoint
echo "Transforming Dockerfile..."
grep -q 'EXPOSE 8000' Dockerfile || sed -i '/^HEALTHCHECK/i EXPOSE 8000' Dockerfile
sed -i 's|ENTRYPOINT.*|ENTRYPOINT ["python", "-m", "awslabs.aws_pricing_mcp_server.server"]|' Dockerfile
grep -q 'EXPOSE 8000' Dockerfile || { echo "ERROR: EXPOSE 8000 not in Dockerfile"; exit 1; }
echo "Dockerfile transformation verified."

# Transform healthcheck
echo "Transforming docker-healthcheck.sh..."
cat > docker-healthcheck.sh << 'HEALTHCHECK_EOF'
#!/bin/bash
curl -sf http://localhost:8000/mcp || exit 1
HEALTHCHECK_EOF
chmod +x docker-healthcheck.sh
echo "Healthcheck transformation verified."

echo "=== All pricing MCP server transformations complete ==="
