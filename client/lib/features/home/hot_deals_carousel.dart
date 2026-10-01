import 'dart:async';
import 'dart:math' as math;

import 'package:api_client/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ui_kit/ui_kit.dart';

import '../../core/orders_controller.dart';
import '../../l10n/app_localizations.dart';
import '../cart/add_to_cart_button.dart';
import '../catalog/item_picture.dart';

/// The rotating hot-deals strip on the home screen (§7.7).
///
/// A `PageView` plus a `Timer`, and nothing more. §7.7's scope cap forbids
/// ranking, personalisation, analytics and custom animation.
///
/// - **Fixed height**, between the search bar and the categories, so it never
///   pushes the category list around.
/// - **Nothing at all** (`SizedBox.shrink`) while loading, on any error, or
///   with no entries. It is decoration: it must never become an error display
///   or a second retry button on home.
/// - **Right to left without help.** In an RTL app a horizontal `PageView`
///   already advances right to left. `reverse: true` would flip it back.
/// - **Pauses** while a finger is on it, and does not move at all when the
///   platform asks for reduced motion.
/// - The timer is cancelled in `dispose`, so leaving home leaves nothing
///   ticking.
class HotDealsCarousel extends ConsumerStatefulWidget {
  const HotDealsCarousel({super.key});

  static const height = 128.0;

  @override
  ConsumerState<HotDealsCarousel> createState() => _HotDealsCarouselState();
}

class _HotDealsCarouselState extends ConsumerState<HotDealsCarousel> {
  final _controller = PageController();
  Timer? _timer;
  Duration? _period;
  int _count = 0;
  bool _held = false;

  /// Keeps exactly one timer running at [period], or none for null.
  /// Idempotent, so calling it from build is safe: it only acts when the
  /// wanted period changes.
  void _schedule(Duration? period) {
    if (period == _period) return;
    _timer?.cancel();
    _timer = period == null ? null : Timer.periodic(period, (_) => _advance());
    _period = period;
  }

  void _advance() {
    if (_held || _count < 2 || !_controller.hasClients) return;
    final next = ((_controller.page ?? 0).round() + 1) % _count;
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deals = ref.watch(hotDealsProvider).value;
    final entries = deals?.entries ?? const <HotDealEntry>[];
    _count = entries.length;

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    _schedule(
      entries.length > 1 && !reduceMotion
          ? Duration(seconds: math.max(1, deals!.rotationSeconds))
          : null,
    );

    if (entries.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 16),
      child: SizedBox(
        height: HotDealsCarousel.height,
        child: Listener(
          onPointerDown: (_) => _held = true,
          onPointerUp: (_) => _held = false,
          onPointerCancel: (_) => _held = false,
          child: PageView.builder(
            controller: _controller,
            itemCount: entries.length,
            itemBuilder: (context, i) => _DealCard(entry: entries[i]),
          ),
        ),
      ),
    );
  }
}

/// One deal: what kind it is, the item's name and price per box, and its
/// picture in a circle with the big + on it.
class _DealCard extends StatelessWidget {
  const _DealCard({required this.entry});

  final HotDealEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.appColors;
    final item = entry.item;
    final tag = switch (entry.kind) {
      HotDealKind.newItem => l10n.dealNew,
      HotDealKind.frequent => l10n.dealFrequent,
      _ => l10n.dealWeekly,
    };

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 2),
      child: Card(
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsetsDirectional.symmetric(horizontal: 10, vertical: 2),
                      decoration: BoxDecoration(color: colors.tag, borderRadius: BorderRadius.circular(10)),
                      child: Text(
                        tag,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: colors.onTag),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.displayName,
                      style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      l10n.pricePerBoxValue(formatIqd(item.pricePerBox)),
                      style: TextStyle(fontSize: 15, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 100,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: colors.tileMint, shape: BoxShape.circle),
                        child: Center(child: ItemPicture.thumb(item.imageUrl, size: 62)),
                      ),
                    ),
                    PositionedDirectional(
                      bottom: -4,
                      end: -4,
                      child: AddToCartButton(item: item, size: 48),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
