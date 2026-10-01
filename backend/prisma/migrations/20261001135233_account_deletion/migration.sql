-- AlterEnum
ALTER TYPE "NotificationType" ADD VALUE 'ACCOUNT_DELETED';

-- AlterTable
ALTER TABLE "users" ADD COLUMN     "deletedAt" TIMESTAMP(3);
