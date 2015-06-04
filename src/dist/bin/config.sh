
# User used for all cluster admin actions
# must also have own databse to login to during inital setup
export ADMIN_USER=postgres

# Primary catalog
export PRIMARY_CATALOG_HOST=localhost
export PRIMARY_CATALOG_PORT=5432
export PRIMARY_CATALOG_DATABASE=kv_catalog
export PSQL_CATALOG="psql -h $PRIMARY_CATALOG_HOST -p $PRIMARY_CATALOG_PORT $PRIMARY_CATALOG_DATABASE"


# Does some extra steps to make it easier to develop.
# TODO turn off by default when installing.
export DEV_MODE=true
