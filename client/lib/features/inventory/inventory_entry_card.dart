import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/formatting.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
import 'stock_labels.dart';

/// One item on the clinic's shelf: its name and status in words, how much is
/// there, how long it should last, where that estimate came from, and any
/// batch that expires soon. A red item carries the big **+** (requirement 12).
///
/// Built for older eyes: large text that wraps rather than truncates, a badge
/// that is a word and an icon as well as a colour, and nothing hidden behind
/// a gesture.
class InventoryEntryCard extends StatelessWidget {
  const InventoryEntryCard({required this.entry, this.onTap, super.key});

  final InventoryEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;
    final source = sourceLabel(l10n, entry.estimate.source);
    final cover = entry.daysOfCover;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(entry.item.displayName, style: text.titleLarge)),
                  const SizedBox(width: 8),
                  StockBadge(level: stockLevel(entry.status), label: stockLabel(l10n, entry)),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(quantityOf(l10n, entry.item, entry.qtyUnits), style: text.titleMedium),
                        // An empty shelf already says «نفد»; a cover line
                        // under it would only confuse.
                        if (entry.qtyUnits > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            cover == null ? l10n.noEstimate : l10n.daysOfCover(cover),
                            style: text.bodyLarge,
                          ),
                        ],
                        if (source != null) ...[
                          const SizedBox(height: 4),
                          Text(source, style: text.bodyMedium),
                        ],
                      ],
                    ),
                  ),
                  if (entry.status == StockStatus.red) ...[
                    const SizedBox(width: 12),
                    AddToCartButton(item: entry.item),
                  ],
                ],
              ),
              for (final batch in entry.expiringBatches) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      batch.expired ? Icons.event_busy : Icons.schedule,
                      color: batch.expired ? colors.danger : colors.stockYellow,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        batch.expired
                            ? l10n.batchExpired(batch.batchNumber, formatCalendarDate(batch.expiryDate))
                            : l10n.batchExpiresOn(
                                batch.batchNumber,
                                formatCalendarDate(batch.expiryDate),
                              ),
                        style: text.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
