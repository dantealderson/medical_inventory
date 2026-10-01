import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/auth_controller.dart';
import '../../core/catalog_controller.dart';
import '../../core/inventory_controller.dart';
import '../../core/notifications_controller.dart';
import '../../core/orders_controller.dart';
import '../../core/router.dart';
import '../../l10n/app_localizations.dart';
import '../home/hot_deals_carousel.dart';
import '../inventory/low_stock_strip.dart';
import '../notifications/notification_bell.dart';
import '../shell/app_bottom_bar.dart';
import 'item_picture.dart';
import 'search_results_view.dart';

/// The client home, after the chosen design (2026-10-01): a green header with
/// the clinic's name, the bell and the search box; this week's deal resting
/// on its edge; six big pastel tiles, one per thing a clinic does; its red
/// items with a +; and the newest items.
///
/// Search happens here, under the box being typed in: while it has text, the
/// results take the place of everything below the header. Clearing it, or
/// the phone's back button, brings the home screen back. The header stays the
/// same sliver in both, so the box keeps its focus and the keyboard stays up.
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
    final query = ref.watch(searchQueryProvider);

    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clear();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // White status-bar icons over the green header.
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          bottomNavigationBar: const AppBottomBar(current: MainTab.home),
          floatingActionButton: const CartFab(),
          floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
          body: CustomScrollView(
            slivers: [
              // One column, so the body paints over the header's edge (a later
              // sliver would paint under it). The header stays its first
              // child either way, so the search box keeps its focus.
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(
                      controller: _search,
                      onChanged: _onChanged,
                      onClear: _clear,
                      overlapped: !_searching,
                    ),
                    if (!_searching) const _HomeBody(),
                  ],
                ),
              ),
              if (_searching)
                SliverFillRemaining(
                  hasScrollBody: true,
                  child: SearchResultsView(pending: _search.text.trim() != query),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How far the first card rests over the header's rounded edge.
const _overlap = 48.0;

class _Header extends ConsumerWidget {
  const _Header({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.overlapped,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  /// Room at the bottom for the card that rests on it.
  final bool overlapped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final auth = ref.watch(authControllerProvider);
    final user = auth is AuthAuthenticated ? auth.user : null;
    final top = MediaQuery.paddingOf(context).top;

    return Container(
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(30)),
      ),
      padding: EdgeInsetsDirectional.fromSTEB(20, top + 18, 20, overlapped ? _overlap + 18 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.hello, style: TextStyle(fontSize: 16, color: colors.onPrimaryMuted)),
                    Text(
                      user?.clinicName ?? user?.username ?? l10n.appTitle,
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: colors.onPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const NotificationBell(),
            ],
          ),
          const SizedBox(height: 14),
          _SearchField(controller: controller, onChanged: onChanged, onClear: onClear),
        ],
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
    final colors = context.appColors;
    final pill = OutlineInputBorder(
      borderRadius: BorderRadius.circular(28),
      borderSide: BorderSide.none,
    );

    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 18),
      decoration: InputDecoration(
        hintText: l10n.searchHint,
        hintStyle: TextStyle(fontSize: 18, color: colors.textMuted),
        prefixIcon: Icon(Icons.search, color: colors.textMuted),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: l10n.clearSearch,
                icon: const Icon(Icons.close),
                onPressed: onClear,
              ),
        contentPadding: const EdgeInsetsDirectional.symmetric(horizontal: 20, vertical: 16),
        border: pill,
        enabledBorder: pill,
        focusedBorder: pill,
      ),
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context) {
    // Lifted onto the header's edge. Whatever comes first (the deal, or the
    // tiles when there is none) rests there.
    return Transform.translate(
      offset: const Offset(0, -_overlap),
      child: const Padding(
        padding: EdgeInsetsDirectional.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HotDealsCarousel(),
            _Tiles(),
            LowStockStrip(),
            _NewItems(),
          ],
        ),
      ),
    );
  }
}

/// One big tile per thing a clinic does, three to a row.
class _Tiles extends ConsumerWidget {
  const _Tiles();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final red = ref.watch(inventoryProvider).value?.items.where((e) => e.status == StockStatus.red).length ?? 0;
    final unread = ref.watch(unreadCountProvider).value ?? 0;

    final tiles = [
      _Tile(l10n.shop, 'shop', colors.tileMint, Routes.shop),
      _Tile(l10n.myInventory, 'inventory', colors.tilePeach, Routes.inventory, badge: red),
      _Tile(l10n.myOrders, 'orders', colors.tileSky, Routes.orders),
      _Tile(l10n.stockCount, 'count', colors.tileLavender, Routes.stockCount),
      _Tile(l10n.notifications, 'bell', colors.tileCream, Routes.notifications, badge: unread),
      _Tile(l10n.myAccount, 'account', colors.tileSage, Routes.account),
    ];

    return GridView.count(
      crossAxisCount: 3,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      children: tiles,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.drawing, this.color, this.route, {this.badge = 0});

  final String label;
  final String drawing;
  final Color color;
  final String route;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;

    return Semantics(
      button: true,
      label: badge > 0 ? '$label، $badge' : label,
      excludeSemantics: true,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('home-tile-$drawing'),
          onTap: () => context.go(route),
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsetsDirectional.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset('assets/illustrations/$drawing.svg', width: 50, height: 50),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: colors.onSurface),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (badge > 0)
                PositionedDirectional(top: 8, end: 8, child: CountBadge(count: badge)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small red circle with a number, as on the tiles.
class CountBadge extends StatelessWidget {
  const CountBadge({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Container(
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: colors.badge, borderRadius: BorderRadius.circular(12)),
      child: Text(
        '$count',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: colors.onPrimary),
      ),
    );
  }
}

/// The newest items, from the hot deals the nightly job marks NEW.
class _NewItems extends ConsumerWidget {
  const _NewItems();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final entries = ref.watch(hotDealsProvider).value?.entries ?? const <HotDealEntry>[];
    final items = [for (final e in entries) if (e.kind == HotDealKind.newItem) e.item];
    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(l10n.newItems, style: text.titleLarge?.copyWith(fontSize: 19))),
              TextButton(onPressed: () => context.go(Routes.shop), child: Text(l10n.seeAll)),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => _NewItemCard(item: items[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _NewItemCard extends StatelessWidget {
  const _NewItemCard({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final text = Theme.of(context).textTheme;

    return SizedBox(
      width: 156,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go(Routes.item(item.id)),
          child: Padding(
            padding: const EdgeInsetsDirectional.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 78,
                  decoration: BoxDecoration(
                    color: colors.pictureBackground,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: ItemPicture.thumb(item.imageUrl, size: 64),
                ),
                const SizedBox(height: 6),
                Text(item.displayName, style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                const Spacer(),
                Text(
                  formatIqd(item.pricePerBox),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: colors.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
