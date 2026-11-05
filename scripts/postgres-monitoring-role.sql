-- Run once on the primary as an administrator: psql -X -v ON_ERROR_STOP=1 -f ...
-- Physical replication copies the role/password to the standby.
-- Re-running preserves the password, but prompts to rotate it at the end.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'observability_monitor') THEN
    CREATE ROLE observability_monitor LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
      NOREPLICATION CONNECTION LIMIT 5;
  END IF;
END
$$;
GRANT pg_monitor TO observability_monitor;
GRANT CONNECT ON DATABASE postgres TO observability_monitor;
ALTER ROLE observability_monitor SET default_transaction_read_only = on;
ALTER ROLE observability_monitor SET statement_timeout = '5s';
-- Interactive prompt avoids storing the password in SQL, shell history or Git.
\password observability_monitor
