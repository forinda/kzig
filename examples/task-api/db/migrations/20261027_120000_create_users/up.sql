-- task-kickdb-api's users table, as its init migration creates it.
CREATE TYPE "global_role" AS ENUM ('superadmin', 'user');
CREATE TABLE "users" (
  "id" uuid NOT NULL DEFAULT gen_random_uuid(),
  "email" varchar(255) NOT NULL,
  "passwordHash" varchar(255) NOT NULL,
  "firstName" varchar(100) NOT NULL,
  "lastName" varchar(100) NOT NULL,
  "avatarUrl" text,
  "globalRole" global_role NOT NULL DEFAULT 'user',
  "isActive" boolean NOT NULL DEFAULT true,
  "lastLoginAt" timestamp,
  "createdAt" timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "updatedAt" timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY ("id")
);
CREATE INDEX "users_name_idx" ON "users" ("firstName", "lastName");
CREATE UNIQUE INDEX "users_email_unique" ON "users" ("email");
