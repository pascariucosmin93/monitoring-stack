#!/usr/bin/env python3
"""Create only the SQL Exporter Secret; never print or persist credentials locally."""
import base64
import getpass
import json
import subprocess
from urllib.parse import quote, urlencode

password = getpass.getpass('Parola rolului observability_monitor: ')
if not password:
    raise SystemExit('Parola nu poate fi goală.')
params = urlencode({'sslmode': 'require', 'connect_timeout': '5',
                    'application_name': 'observability-postgres'})
data = {}
for key, host in [('postgress_dsn', '192.168.1.16'), ('postgress_1_dsn', '192.168.1.17')]:
    dsn = f'postgresql://observability_monitor:{quote(password, safe="")}@{host}:5432/postgres?{params}'
    data[key] = base64.b64encode(dsn.encode()).decode()
secret = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
          'metadata': {'name': 'postgres-monitoring', 'namespace': 'observability'},
          'data': data}
# Pass credentials over stdin, never in process arguments or command output.
subprocess.run(['kubectl', 'apply', '-f', '-'], input=json.dumps(secret), text=True, check=True)
print('Secret creat. La rotație, repornește cele două Deployment-uri postgres-exporter.')
