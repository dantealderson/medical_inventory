import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/catalog_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../cart/cart_badge_button.dart';
import '../home/hot_deals_carousel.dart';
import '../inventory/low_stock_strip.dart';
import '../notifications/notification_bell.dart';
import 'item_card.dart';
import 'item_picture.dart';
import 'search_results_view.dart';

enum _HomeMenu { logout, deleteAccount }

/// Log out, after a «هل تريد…» question.
Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.logoutQuestion),
      content: Text(l10n.logoutExplained),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.confirmLogout),
        ),
      ],
    ),
  );
  if (ok == true) await ref.read(authControllerProvider.notifier).logout();
}

/// The client home: a search bar, a big «مخزوني» button, the rotating hot
/// deals, the clinic's red items, and the top-level categories.
///
/// Search happens here, under the box being typed in: while it has text, the
/// results take the place of everything below it. Clearing it, or the phone's
/// back button, brings the home screen back.
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  // Starts from the last search, so coming back from an item shows the same
  // results instead of an empty box.
  late final _search = TextEditingController(text: ref.read(searchQueryProvider));

  bool get _searching => _search.text.trim().isNotEmpty;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // Debounced in the controller — see SearchQuery.
    ref.read(searchQueryProvider.notifier).update(value);
    setState(() {});
  }

  void _clear() {
    _search.clear();
    ref.read(searchQueryProvider.notifier).update('');
    FocusScope.of(context).unfocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = ref.watch(searchQueryProvider);

    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clear();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          const NotificationBell(),
          IconButton(
            tooltip: l10n.myOrders,
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => context.go(Routes.orders),
          ),
          const CartBadgeButton(),
          // Log out lives in a menu and asks first. As a bare icon beside the
          // cart, one slip of the finger signed the clinic out.
          PopupMenuButton<_HomeMenu>(
            tooltip: l10n.more,
            onSelected: (choice) => switch (choice) {
              _HomeMenu.logout => _confirmLogout(context, ref),
              _HomeMenu.deleteAccount => context.go(Routes.deleteAccount),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _HomeMenu.logout,
                child: ListTile(
                  leading: const Icon(Icons.logout),
                  title: Text(l10n.logout),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              // Last, and a page of its own that asks twice: it cannot be undone.
              PopupMenuItem(
                value: _HomeMenu.deleteAccount,
                child: ListTile(
                  leading: const Icon(Icons.person_remove_outlined),
                  title: Text(l10n.deleteAccount),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _SearchField(controller: _search, onChanged: _onChanged, onClear: _clear),
          if (_searching)
            Expanded(child: SearchResultsView(pending: _search.text.trim() != query))
          else ...[
            const _MyInventoryButton(),
            const HotDealsCarousel(),
            const LowStockStrip(),
            const Expanded(child: _Categories()),
          ],
        ],
      ),
      ),
    );
  }
}

class _Categories extends ConsumerWidget {
  const _Categories();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(categoryTreeProvider),
      child: AsyncSection<List<Category>>(
        value: ref.watch(categoryTreeProvider),
        onRetry: () => ref.invalidate(categoryTreeProvider),
        emptyMessage: l10n.noCategoriesYet,
        isEmpty: (data) => data.isEmpty,
        builder: (roots) => ListView.builder(
          padding: const EdgeInsetsDirectional.all(16),
          itemCount: roots.length,
          itemBuilder: (context, i) => CategoryTile(category: roots[i]),
        ),
      ),
    );
  }
}

/// A labelled, full-width button rather than an app-bar icon: My Inventory is
/// the clinic's core screen, and an unlabelled icon is easy to miss.
class _MyInventoryButton extends StatelessWidget {
  const _MyInventoryButton();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: () => context.go(Routes.inventory),
        icon: const Icon(Icons.inventory_2_outlined),
        label: Text(l10n.myInventory),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsetsDirectional.all(16),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: l10n.searchHint,
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: l10n.clearSearch,
                  icon: const Icon(Icons.close),
                  onPressed: onClear,
                ),
          border: const OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.search,
        onChanged: onChanged,
      ),
    );
  }
}

/// A category row. Drills into children if it has any, otherwise into items.
class CategoryTile extends StatelessWidget {
  const CategoryTile({required this.category, super.key});

  final Category category;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;

    return Card(
      margin: const EdgeInsetsDirectional.only(bottom: 12),
      child: ListTile(
        leading: category.imageUrl == null ? null : ItemPicture.thumb(category.imageUrl, size: 48),
        title: Text(category.displayName),
        // A level-1 category with children drills into them; a leaf goes
        // straight to its items. Either way the destination is the same
        // route, which decides based on what it finds.
        trailing: Icon(Icons.chevron_left, color: colors.border),
        onTap: () => context.go(Routes.category(category.id)),
      ),
    );
  }
}
