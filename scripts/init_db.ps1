# Stop on errors
$ErrorActionPreference = "Stop"

# Function to write to stderr
function Write-ErrorOutput {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

# Check if sqlx is installed
if (-not (Get-Command sqlx -ErrorAction SilentlyContinue)) {
    Write-ErrorOutput "Error: sqlx is not installed."
    Write-ErrorOutput "Use:"
    Write-ErrorOutput "    cargo install --version='~0.8' sqlx-cli --no-default-features --features rustls,postgres"
    Write-ErrorOutput "to install it."
    exit 1
}

# Check if docker is installed
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-ErrorOutput "Error: docker is not installed or not in PATH."
    Write-ErrorOutput "Please ensure Docker Desktop is installed and running, or that 'docker' command is accessible from PowerShell."
    exit 1
}

# Check if a custom parameter has been set, otherwise use default values
$DB_PORT = if (-not [string]::IsNullOrEmpty($env:DB_PORT)) { $env:DB_PORT } else { "5432" }
$SUPERUSER = if (-not [string]::IsNullOrEmpty($env:SUPERUSER)) { $env:SUPERUSER } else { "postgres" }
$SUPERUSER_PWD = if (-not [string]::IsNullOrEmpty($env:SUPERUSER_PWD)) { $env:SUPERUSER_PWD } else { "password" }
$APP_USER = if (-not [string]::IsNullOrEmpty($env:APP_USER)) { $env:APP_USER } else { "app" }
$APP_USER_PWD = if (-not [string]::IsNullOrEmpty($env:APP_USER_PWD)) { $env:APP_USER_PWD } else { "secret" }
$APP_DB_NAME = if (-not [string]::IsNullOrEmpty($env:APP_DB_NAME)) { $env:APP_DB_NAME } else { "newsletter" }


# Allow to skip Docker if a dockerized Postgres database is already running
if ([string]::IsNullOrEmpty($env:SKIP_DOCKER)) {
    # if a postgres container is running, print instructions to kill it and exit
    $RUNNING_POSTGRES_CONTAINER = (docker ps --filter "name=postgres" --format "{{.ID}}" | Out-String).Trim()
    if (-not [string]::IsNullOrEmpty($RUNNING_POSTGRES_CONTAINER)) {
        Write-ErrorOutput "There is a postgres container already running, kill it with"
        Write-ErrorOutput "    docker kill $RUNNING_POSTGRES_CONTAINER"
        exit 1
    }

    $CONTAINER_NAME = "postgres_$(Get-Date -Format "yyyyMMddHHmmss")" # Using a more standard date format for container name

    # Launch postgres using Docker
    docker run `
        --env "POSTGRES_USER=$SUPERUSER" `
        --env "POSTGRES_PASSWORD=$SUPERUSER_PWD" `
        --health-cmd="pg_isready -U $SUPERUSER || exit 1" `
        --health-interval=1s `
        --health-timeout=5s `
        --health-retries=5 `
        --publish "${DB_PORT}:5432" `
        --detach `
        --name "$CONTAINER_NAME" `
        postgres -N 1000

    Write-ErrorOutput "Waiting for Postgres to become healthy..."
    do {
        Start-Sleep -Seconds 1
        $HEALTH_STATUS = (docker inspect -f "{{.State.Health.Status}}" $CONTAINER_NAME | Out-String).Trim()
        if ($HEALTH_STATUS -eq "healthy") {
            Write-ErrorOutput "Postgres is healthy!"
            break
        }
        Write-ErrorOutput "Postgres is still unavailable - sleeping"
    } while ($true)

    # Create the application user
    $CREATE_QUERY = "CREATE USER $APP_USER WITH PASSWORD '$APP_USER_PWD';"
    docker exec -it $CONTAINER_NAME psql -U $SUPERUSER -c "$CREATE_QUERY"

    # Grant create db privileges to the app user
    $GRANT_QUERY = "ALTER USER $APP_USER CREATEDB;"
    docker exec -it $CONTAINER_NAME psql -U $SUPERUSER -c "$GRANT_QUERY"
}

Write-ErrorOutput "Postgres is up and running on port $DB_PORT - running migrations now!"

# Create the application database
$env:DATABASE_URL = "postgres://${APP_USER}:${APP_USER_PWD}@localhost:${DB_PORT}/${APP_DB_NAME}"
sqlx database create
sqlx migrate run

Write-ErrorOutput "Postgres has been migrated, ready to go!"
