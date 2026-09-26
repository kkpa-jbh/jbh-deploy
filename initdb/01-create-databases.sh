#!/bin/sh
# Runs once, on the first start of jbh-postgres (empty volume).
# The image already created the IAM database "jbh" (POSTGRES_DB).
# This adds "jbh_finance" and the same settings the local Makefiles create:
#   - jbh-iam/Makefile db-create: pgcrypto extension, America/Bogota time zone
#   - jbh-personal-finance module *.mk files: one schema per module
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname jbh <<SQL
CREATE DATABASE jbh_finance OWNER "$POSTGRES_USER";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
ALTER DATABASE jbh SET TIME ZONE 'America/Bogota';
ALTER DATABASE jbh_finance SET TIME ZONE 'America/Bogota';
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname jbh_finance <<SQL
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS finance AUTHORIZATION "$POSTGRES_USER";
CREATE SCHEMA IF NOT EXISTS preferences AUTHORIZATION "$POSTGRES_USER";
CREATE SCHEMA IF NOT EXISTS notifications AUTHORIZATION "$POSTGRES_USER";
SQL
