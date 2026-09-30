import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Sends the phone's back button to [route].
///
/// Every client page is shown on its own (`context.go` replaces the page), so
/// the back button used to close the app from any screen. Wrap a page in this,
/// or use [BackArrow], which includes it.
class BackTo extends StatelessWidget {
  const BackTo(this.route, {required this.child, super.key});

  final String route;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.go(route);
      },
      child: child,
    );
  }
}

/// A page's app-bar back arrow. The phone's back button goes to the same
/// [route], so the two can never disagree.
class BackArrow extends StatelessWidget {
  const BackArrow(this.route, {super.key});

  final String route;

  @override
  Widget build(BuildContext context) {
    return BackTo(
      route,
      child: IconButton(
        icon: const BackButtonIcon(),
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: () => context.go(route),
      ),
    );
  }
}
