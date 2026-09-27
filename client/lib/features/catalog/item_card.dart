import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/router.dart';
import '../../l10n/app_localizations.dart';

/// One item in a list.
///
/// Shows the two numbers a clinic decides on: what a box costs and how many
/// units are in it. Phase 3 adds the large **+** quick-add button here.
class ItemCard extends StatelessWidget {
  const ItemCard({required this.item, super.key});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: InkWell(
        onTap: () => context.go(Routes.item(item.id)),
        child: Padding(
          padding: const EdgeInsetsDirectional.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: text.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.unitsPerBox} ${item.unitLabelAr} / ${l10n.boxesShort}',
                      style: text.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${l10n.pricePerBox}: ${item.pricePerBox}',
                      style: text.titleSmall?.copyWith(color: colors.primary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_left, color: colors.border),
            ],
          ),
        ),
      ),
    );
  }
}

/// Loading / error / empty, shared by every catalog screen.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    required this.value,
    required this.onRetry,
    required this.emptyMessage,
    required this.isEmpty,
    required this.builder,
    super.key,
  });

  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final String emptyMessage;
  final bool Function(T data) isEmpty;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;

    return value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.error_outline, size: 48, color: colors.danger),
          const SizedBox(height: 12),
          Center(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 24),
              child: Text(
                // Always the server's Arabic message, never a raw Dio string.
                e is ApiException ? e.messageAr : l10n.retry,
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: onRetry, child: Text(l10n.retry))),
        ],
      ),
      data: (data) => isEmpty(data)
          ? ListView(
              children: [
                const SizedBox(height: 120),
                Center(child: Text(emptyMessage, style: Theme.of(context).textTheme.bodyLarge)),
              ],
            )
          : builder(data),
    );
  }
}
