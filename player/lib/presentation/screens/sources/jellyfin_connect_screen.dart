/// Connecting a Jellyfin server: its address, then a Quick Connect code to
/// approve elsewhere or a username and password.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/sources_providers.dart';
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import 'jellyfin_sign_in_controller.dart';
import 'sign_in_problem.dart';

class JellyfinConnectScreen extends ConsumerStatefulWidget {
  const JellyfinConnectScreen({super.key, this.reauthAccountId});

  final String? reauthAccountId;

  @override
  ConsumerState<JellyfinConnectScreen> createState() =>
      _JellyfinConnectScreenState();
}

class _JellyfinConnectScreenState extends ConsumerState<JellyfinConnectScreen> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    final id = widget.reauthAccountId;
    if (id != null) {
      final source = ref
          .read(thirdPartySourcesProvider)
          .where((s) => s.account.id == id)
          .firstOrNull;
      final uri = source?.server.connections.firstOrNull?.uri;
      if (uri != null) _url.text = uri.toString();
      if (source != null) _user.text = source.profile.name;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  JellyfinSignInController get _ctl =>
      ref.read(jellyfinSignInProvider(widget.reauthAccountId).notifier);

  @override
  Widget build(BuildContext context) {
    final provider = jellyfinSignInProvider(widget.reauthAccountId);
    ref.listen(provider, (_, next) {
      if (next is JellyfinSignedIn) context.go(sourceHomeLocation(next.source));
    });
    final state = ref.watch(provider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.sourcesJellyfinConnectTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: switch (state) {
              JellyfinEnterAddress(:final error) => _address(error),
              JellyfinChecking() || JellyfinSignedIn() => const [
                  Center(child: CircularProgressIndicator()),
                ],
              JellyfinQuickConnect(:final code, :final expired) =>
                _quickConnect(context, code, expired),
              JellyfinPassword(:final error, :final quickConnectAvailable) =>
                _passwordForm(error, quickConnectAvailable),
            },
          ),
        ),
      ),
    );
  }

  Widget _error(SignInProblem? error) => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(context.l10n.signInProblemText(error),
              key: const Key('jellyfin-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        );

  List<Widget> _address(SignInProblem? error) => [
        TextField(
          key: const Key('jellyfin-url-field'),
          controller: _url,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: context.l10n.sourcesServerAddressLabel,
            hintText: 'http://192.168.1.30:8096', // l10n-ignore: example URL
          ),
          onSubmitted: (_) => _ctl.submitAddress(_url.text),
        ),
        _error(error),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('jellyfin-continue-button'),
          onPressed: () => _ctl.submitAddress(_url.text),
          child: Text(context.l10n.commonContinue),
        ),
      ];

  List<Widget> _quickConnect(BuildContext context, String code, bool expired) {
    final theme = Theme.of(context);
    return [
      Text(
        expired
            ? context.l10n.sourcesJellyfinCodeExpired
            : context.l10n.sourcesJellyfinApproveCode,
        style: theme.textTheme.titleMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 16),
      if (!expired)
        SelectableText(
          code,
          key: const Key('jellyfin-quick-connect-code'),
          textAlign: TextAlign.center,
          style: theme.textTheme.displayMedium
              ?.copyWith(letterSpacing: 8, fontWeight: FontWeight.w600),
        ),
      if (expired)
        FilledButton(
          key: const Key('jellyfin-new-code-button'),
          autofocus: true,
          onPressed: _ctl.startQuickConnect,
          child: Text(context.l10n.sourcesJellyfinNewCode),
        ),
      const SizedBox(height: 24),
      TextButton(
        key: const Key('jellyfin-use-password-button'),
        autofocus: !expired,
        onPressed: _ctl.usePassword,
        child: Text(context.l10n.sourcesJellyfinUsePassword),
      ),
    ];
  }

  List<Widget> _passwordForm(
          SignInProblem? error, bool quickConnectAvailable) =>
      [
        TextField(
          key: const Key('jellyfin-username-field'),
          controller: _user,
          autofocus: true,
          decoration:
              InputDecoration(labelText: context.l10n.loginUsernameLabel),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('jellyfin-password-field'),
          controller: _password,
          obscureText: true,
          decoration:
              InputDecoration(labelText: context.l10n.loginPasswordLabel),
          onSubmitted: (_) => _ctl.submitPassword(_user.text, _password.text),
        ),
        _error(error),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('jellyfin-sign-in-button'),
          onPressed: () => _ctl.submitPassword(_user.text, _password.text),
          child: Text(context.l10n.loginSignIn),
        ),
        if (quickConnectAvailable) ...[
          const SizedBox(height: 8),
          TextButton(
            key: const Key('jellyfin-use-quick-connect-button'),
            onPressed: _ctl.startQuickConnect,
            child: Text(context.l10n.sourcesJellyfinUseQuickConnect),
          ),
        ],
      ];
}
