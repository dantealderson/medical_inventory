import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/catalog_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';

/// Full detail for one item.
///
/// It carries the large **+** that adds a box to the cart.
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
        leading: IconButton(
          icon: const BackButtonIcon(),
          onPressed: () => context.go(Routes.home),
        ),
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
