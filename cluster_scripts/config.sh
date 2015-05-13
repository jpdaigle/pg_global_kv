
# User used for all cluster admin actions
# must also have own databse to login to during inital setup
export ADMIN_USER=postgres

# Primary catalog
export PRIMARY_CATALOG_HOST=localhost
export PRIMARY_CATALOG_PORT=5432
export PRIMARY_CATALOG_DATABASE=kv_catalog

# Dev only settings
export RECREATE_EXISITING_NODES=true
