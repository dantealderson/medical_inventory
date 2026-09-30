-- CreateTable
CREATE TABLE "media_files" (
    "id" TEXT NOT NULL,
    "full" BYTEA NOT NULL,
    "thumb" BYTEA NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "media_files_pkey" PRIMARY KEY ("id")
);
