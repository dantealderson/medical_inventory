/**
 * The FEFO planner (spec §7.3): which batch gives how much, with no I/O.
 *
 * It trusts the ORDER of `candidates`. AllocationService loads them with
 * ORDER BY "itemId", "expiryDate", "receivedAt", id, which puts the earliest
 * expiry first. The same statement fixes the order its row locks are taken
 * in. Sorting lives in that one query, so the planner and the lock order can
 * never disagree. Re-sorting here would be a second definition of "first".
 */

export interface CandidateBatch {
  id: string;
  itemId: string;
  qtyUnitsRemaining: number;
}

export interface AllocatedPortion {
  batchId: string;
  qtyUnits: number;
}

export interface PlanRequest {
  /** Echoed back on the planned line. AllocationService passes the orderLineId. */
  key: string;
  itemId: string;
  qtyUnits: number;
}

export interface PlannedLine {
  key: string;
  itemId: string;
  allocated: AllocatedPortion[];
  qtyUnitsAllocated: number;
  /** Requested minus allocated. A shortage is reported, never thrown. */
  shortBy: number;
}

/** Greedy earliest-first. Consumes a shared remaining map so two requests for one item never double-count. */
export function planFefo(candidates: CandidateBatch[], requests: PlanRequest[]): PlannedLine[] {
  // Shared across every request. Two lines for the same item cannot occur in
  // one order (@@unique([orderId, itemId])), but a preview is not an order,
  // and promising the same units twice is exactly the oversell the rest of
  // this phase exists to prevent.
  const remaining = new Map<string, number>();
  for (const candidate of candidates) {
    remaining.set(candidate.id, Math.max(0, candidate.qtyUnitsRemaining));
  }

  return requests.map((request) => {
    if (!Number.isInteger(request.qtyUnits) || request.qtyUnits < 0) {
      throw new Error(
        `planFefo: qtyUnits must be a non-negative integer, got ${request.qtyUnits} for ${request.key}`,
      );
    }

    const allocated: AllocatedPortion[] = [];
    let outstanding = request.qtyUnits;

    for (const candidate of candidates) {
      if (outstanding === 0) break;
      if (candidate.itemId !== request.itemId) continue;

      const available = remaining.get(candidate.id) ?? 0;
      if (available === 0) continue;

      const take = Math.min(outstanding, available);
      allocated.push({ batchId: candidate.id, qtyUnits: take });
      remaining.set(candidate.id, available - take);
      outstanding -= take;
    }

    return {
      key: request.key,
      itemId: request.itemId,
      allocated,
      qtyUnitsAllocated: request.qtyUnits - outstanding,
      shortBy: outstanding,
    };
  });
}
