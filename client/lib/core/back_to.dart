import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Leaves for [route], after [confirm] agrees when there is one.
Future<void> _leave(BuildContext context, String route, Future<bool> Function()? confirm) async {
  if (confirm != null && !await confirm()) return;
  if (context.mounted) context.go(route);
}

/// Sends the phone's back button to [route].
///
/// Every client page is shown on its own (`context.go` replaces the page), so
/// the back button used to close the app from any screen. Wrap a page in this,
/// or use [BackArrow], which includes it.
class BackTo extends StatelessWidget {
  const BackTo(this.route, {required this.child, this.confirm, super.key});

  final String route;
  final Widget child;

  /// Asked before leaving, by a page that would lose what was typed. The page
  /// is left only when it answers true.
  final Future<bool> Function()? confirm;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(context, route, confirm);
      },
      child: child,
    );
  }
}

/// A page's app-bar back arrow. The phone's back button goes to the same
/// [route], and asks the same [confirm], so the two can never disagree.
class BackArrow extends StatelessWidget {
  const BackArrow(this.route, {this.confirm, super.key});

  final String route;
  final Future<bool> Function()? confirm;

  @override
  Widget build(BuildContext context) {
    return BackTo(
      route,
      confirm: confirm,
      child: IconButton(
        icon: const BackButtonIcon(),
        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
        onPressed: () => _leave(context, route, confirm),
      ),
    );
  }
}
