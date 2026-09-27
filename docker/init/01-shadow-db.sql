-- Prisma replays migrations into a throwaway database when diffing
-- (`prisma migrate diff --from-migrations`), which is how you READ a
-- migration before applying it. `migrate diff` will not create this database
-- itself, so it is created here at container init.
CREATE DATABASE medinv_shadow;

-- The e2e and integration suites truncate tables between tests. Running them
-- against the development database destroys the seeded admin and anything
-- else being worked with, so they get their own database.
CREATE DATABASE medinv_test;
