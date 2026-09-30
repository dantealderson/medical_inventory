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

/// Full detail for one item.
///
/// It carries the large **+** that adds a box to the cart, and the expiry of
/// the stock the clinic would actually receive (§12.2).
class ItemDetailScreen extends ConsumerWidget {
  const ItemDetailScreen({required this.itemId, super.key});

  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final item = ref.watch(itemDetailProvider(itemId));
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.items),
        leading: const BackArrow(Routes.home),
      ),
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
        data: (data) => SingleChildScrollView(
          padding: const EdgeInsetsDirectional.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(data.displayName, style: text.headlineSmall),
              // Both names when both exist — a supplier catalogue and a
              // clinic's shelf label are often in different languages.
              if (data.nameEn != null && data.nameAr != null) ...[
                const SizedBox(height: 4),
                Text(data.nameEn!, style: text.bodyMedium),
              ],
              const SizedBox(height: 24),
              _DetailRow(
                label: l10n.unitsPerBox,
                value: '${data.unitsPerBox} ${data.unitLabelAr}',
              ),
              const SizedBox(height: 12),
              _DetailRow(label: l10n.pricePerBox, value: data.pricePerBox),
              const SizedBox(height: 12),
              _NextExpiry(itemId: itemId),
              const SizedBox(height: 24),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AddToCartButton(item: data, size: 64),
              ),
              if (data.description != null) ...[
                const SizedBox(height: 24),
                Text(
                  data.description!,
                  style: text.bodyMedium?.copyWith(color: colors.onSurface),
                ),
              ],
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
    final text = Theme.of(context).textTheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: text.bodyMedium),
        Text(value, style: text.titleSmall),
      ],
    );
  }
}
