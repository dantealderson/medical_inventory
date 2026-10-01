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

  static const height = 112.0;

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

    return SizedBox(
      height: HotDealsCarousel.height,
      child: Listener(
        onPointerDown: (_) => _held = true,
        onPointerUp: (_) => _held = false,
        onPointerCancel: (_) => _held = false,
        child: PageView.builder(
          controller: _controller,
          itemCount: entries.length,
          itemBuilder: (context, i) => _DealCard(item: entries[i].item),
        ),
      ),
    );
  }
}

class _DealCard extends StatelessWidget {
  const _DealCard({required this.item});

  final Item item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = Theme.of(context).textTheme;
    final colors = context.appColors;

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        margin: EdgeInsetsDirectional.zero,
        child: Padding(
          padding: const EdgeInsetsDirectional.all(12),
          child: Row(
            children: [
              ItemPicture.thumb(item.imageUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayName,
                      style: text.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${l10n.pricePerBox}: ${formatIqd(item.pricePerBox)}',
                      style: text.bodySmall?.copyWith(color: colors.primary),
                    ),
                  ],
                ),
              ),
              AddToCartButton(item: item, size: 48),
            ],
          ),
        ),
      ),
    );
  }
}
