-- Prisma replays migrations into a throwaway database when diffing
-- (`prisma migrate diff --from-migrations`), which is how you READ a
-- migration before applying it. `migrate diff` will not create this database
-- itself, so it is created here at container init.
CREATE DATABASE medinv_shadow;
