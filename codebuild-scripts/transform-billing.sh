#!/bin/bash
set -euo pipefail

echo "=== Transformation Script: Clone and Transform Billing MCP Server ==="

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
cd mcp/src/billing-cost-management-mcp-server

SERVER_FILE="awslabs/billing_cost_management_mcp_server/server.py"

# Transform server.py
echo "Transforming server.py..."

python3 -c "
import re

with open('$SERVER_FILE', 'r') as f:
    content = f.read()

# 1. Patch FastMCP constructor: no changes needed, we pass params to run() instead
print('FastMCP constructor: no patch needed (params passed to run())')

# 2. Replace main() function
old_main = '''def main():
    \"\"\"Main entry point for the server.\"\"\"
    # Run the setup function to initialize the server
    asyncio.run(setup())

    # Start the MCP server
    mcp.run()'''

new_main = '''def main():
    \"\"\"Run the MCP server with streamable-http transport.\"\"\"
    # Run setup before starting server
    asyncio.run(setup())
    # Run with streamable-http transport on port 8000
    mcp.run(transport='streamable-http', host='0.0.0.0', port=8000, stateless_http=True)'''

if old_main in content:
    content = content.replace(old_main, new_main)
    print('main() function patched')
else:
    print('ERROR: Could not find expected main() function pattern')
    # Print what we found for debugging
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
echo "server.py transformation verified."

# No need to add uvicorn/starlette — fastmcp handles streamable-http transport internally
echo "Dependencies: fastmcp handles streamable-http transport natively."

# Keep billing on its declared fastmcp 3.x (its source imports fastmcp.tools.ToolResult,
# a 3.x-only symbol, so it CANNOT run on fastmcp 2.x). fastmcp 3.x turns on a
# DNS-rebinding Host/Origin guard by default, which rejects the AgentCore Gateway's
# cross-host request (Host: bedrock-agentcore.<region>.amazonaws.com) with HTTP 421.
# We disable that guard via the container env var below rather than downgrading.

# Disable UV_FROZEN in Dockerfile
echo "Disabling UV_FROZEN in Dockerfile..."
sed -i 's/UV_FROZEN=1/UV_FROZEN=0/g' Dockerfile
sed -i '/ENV UV_FROZEN/d' Dockerfile
echo "UV_FROZEN handling complete."

# Disable fastmcp 3.x's DNS-rebinding Host/Origin protection so the AgentCore
# Gateway (which connects with Host: bedrock-agentcore.<region>.amazonaws.com,
# not localhost) is not rejected with HTTP 421 Misdirected Request. fastmcp reads
# FASTMCP_HTTP_HOST_ORIGIN_PROTECTION from the env (settings.http_host_origin_protection,
# default True); the streamable-http transport passes it through as
# host_origin_protection. Safe here: the runtime is reachable only behind the
# authenticated AgentCore Gateway, not a browser-facing public endpoint.
echo "Disabling fastmcp Host/Origin protection via Dockerfile ENV..."
grep -q 'FASTMCP_HTTP_HOST_ORIGIN_PROTECTION' Dockerfile || \
    sed -i '/^HEALTHCHECK/i ENV FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false' Dockerfile
grep -q 'FASTMCP_HTTP_HOST_ORIGIN_PROTECTION=false' Dockerfile || { echo "ERROR: FASTMCP_HTTP_HOST_ORIGIN_PROTECTION not set in Dockerfile"; exit 1; }
echo "Host/Origin protection disabled in Dockerfile."

# Transform Dockerfile: add EXPOSE and update entrypoint
echo "Transforming Dockerfile..."
grep -q 'EXPOSE 8000' Dockerfile || sed -i '/^HEALTHCHECK/i EXPOSE 8000' Dockerfile
sed -i 's|ENTRYPOINT.*|ENTRYPOINT ["python", "-m", "awslabs.billing_cost_management_mcp_server.server"]|' Dockerfile
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

echo "=== All billing MCP server transformations complete ==="
