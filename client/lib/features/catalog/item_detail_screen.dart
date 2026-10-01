import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/catalog_controller.dart';
import '../../core/formatting.dart';
import '../../core/orders_controller.dart';
import '../../core/back_to.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
import 'item_picture.dart';

/// Full detail for one item, in the style of the chosen design: a big
/// picture, the name, what is in a box and when the stock the clinic would
/// receive expires (§12.2), and a bar at the bottom with the price and the
/// large **+** that adds a box to the cart.
class ItemDetailScreen extends ConsumerWidget {
  const ItemDetailScreen({required this.itemId, this.fromSection, super.key});

  final String itemId;

  /// The section whose grid opened this item, if one did.
  final String? fromSection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final item = ref.watch(itemDetailProvider(itemId));
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;
    final data = item.value;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.items),
        // Back where it was opened: its section's grid, or home (where a
        // search still shows its results).
        leading: BackArrow(fromSection == null ? Routes.home : Routes.category(fromSection!)),
      ),
      bottomNavigationBar: data == null ? null : _PriceBar(item: data),
      body: item.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsetsDirectional.all(24),
            child: Text(
              // The server's Arabic message, never a raw transport string.
              e is ApiException ? e.messageAr : l10n.retry,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (data) => ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 20, 24),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: ColoredBox(
                color: colors.pictureBackground,
                child: SizedBox(
                  height: 240,
                  child: Center(
                    child: data.imageUrl == null
                        ? ItemPicture.thumb(null, size: 120)
                        : ItemPicture.full(data.imageUrl, height: 240),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(data.displayName, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            // Both names when both exist: a supplier catalogue and a
            // clinic's shelf label are often in different languages.
            if (data.nameEn != null && data.nameAr != null)
              Text(data.nameEn!, style: TextStyle(fontSize: 16, color: colors.textMuted)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
                child: Column(
                  children: [
                    _DetailRow(
                      label: l10n.unitsPerBox,
                      value: '${data.unitsPerBox} ${data.unitLabelAr}',
                    ),
                    _NextExpiry(itemId: itemId),
                  ],
                ),
              ),
            ),
            if (data.description != null) ...[
              const SizedBox(height: 16),
              Text(data.description!, style: text.bodyLarge),
            ],
          ],
        ),
      ),
    );
  }
}

/// The bar at the bottom: the price of a box, and the big + beside it.
class _PriceBar extends StatelessWidget {
  const _PriceBar({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return Material(
      color: colors.surface,
      elevation: 8,
      shadowColor: colors.shadow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 12, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.pricePerBox, style: TextStyle(fontSize: 14, color: colors.textMuted)),
                    Text(
                      formatIqd(item.pricePerBox),
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: colors.primary),
                    ),
                  ],
                ),
              ),
              AddToCartButton(item: item, size: 64),
            ],
          ),
        ),
      ),
    );
  }
}

/// What an order confirmed now would receive: the expiry of the batch the
/// warehouse would ship first, by the same shelf-life rule it allocates with.
/// A date, never a quantity. Hidden while loading or when it cannot be read,
/// because it is helpful, not essential.
class _NextExpiry extends ConsumerWidget {
  const _NextExpiry({required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final availability = ref.watch(itemAvailabilityProvider(itemId)).value;
    if (availability == null) return const SizedBox.shrink();

    final date = availability.nextExpiryDate;
    if (!availability.inStock || date == null) {
      return Text(
        l10n.currentlyUnavailable,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.appColors.danger),
      );
    }
    return _DetailRow(label: l10n.nextExpiry, value: formatCalendarDate(date));
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 16, color: colors.textMuted))),
          Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
