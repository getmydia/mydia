import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/auth/auth_service.dart';
import '../../core/layout/window_chrome_inset.dart';
import '../../core/player/input_capabilities.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/palette.dart';
import '../../l10n/l10n.dart';
import '../widgets/focus_highlight.dart';
import '../widgets/glass_surface.dart';
import '../widgets/pin_code_display.dart';
import '../widgets/storage_unavailable_dialog.dart';
import '../widgets/toast/toaster.dart';
import '../widgets/tv_keypad.dart';
import '../widgets/window_chrome/window_title_row.dart';
import '../widgets/channel_badge.dart';
import 'detail/detail_links.dart';
import 'login/login_controller.dart';
import 'sources/add_source_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.reauthAccountId});

  /// Set when signing in again to this account, which the server must be.
  final String? reauthAccountId;

  /// Whether to offer the camera QR scanner.
  ///
  /// Withheld in the directional tier: a Chromecast with Google TV has no
  /// camera, so the button opens a scanner that can only fail, and it sits
  /// between the claim-code field and the submit button in the focus order.
  /// The typed claim code needs no camera, so nothing is lost by removing it.
  @visibleForTesting
  static bool offersQrScan({required bool directionalPrimary}) =>
      !directionalPrimary;

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  /// A re-auth, or a screen pushed over another one (Add a server), rather
  /// than the first sign-in of a fresh install.
  bool get _isAdding =>
      widget.reauthAccountId != null || Navigator.canPop(context);

  final _formKey = GlobalKey<FormState>();
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _claimCodeController = TextEditingController();
  final _relayUrlController = TextEditingController();
  final _totpController = TextEditingController();
  final _serverUrlFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _claimCodeFocus = FocusNode();
  final _relayUrlFocus = FocusNode();
  final _totpFocus = FocusNode();
  final _tvSettingsFocusNode = FocusNode(debugLabel: 'tv-settings-button');
  final _closeSettingsFocusNode =
      FocusNode(debugLabel: 'settings-close-button');
  final _settingsOverlayScopeNode =
      FocusScopeNode(debugLabel: 'settings-overlay-scope');

  bool _obscurePassword = true;
  bool _showDirectConnection = false;
  bool _showQrScanner = false;
  bool _showAdvancedSettings = false;
  bool _isRelayUrlModified = false;
  MobileScannerController? _scannerController;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _claimCodeController.addListener(_onClaimCodeChanged);
    _loadSavedRelayUrl();
    _setupAnimations();
  }

  void _onClaimCodeChanged() {
    if (mounted) setState(() {});
  }

  void _setupAnimations() {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));

    _animationController.forward();
  }

  Future<void> _loadSavedRelayUrl() async {
    final authService = ref.read(authServiceProvider);
    final savedRelayUrl = await authService.getRelayUrl();
    if (mounted) {
      setState(() {
        // Use saved relay URL or default
        _relayUrlController.text = savedRelayUrl ?? defaultRelayUrl;
        _isRelayUrlModified = savedRelayUrl != null;
      });
    }
  }

  Future<void> _saveRelayUrl() async {
    final newUrl = _relayUrlController.text.trim();
    final authService = ref.read(authServiceProvider);

    // Check if it's different from default
    if (newUrl == defaultRelayUrl || newUrl.isEmpty) {
      // Clear custom relay URL (use default)
      await authService.clearRelayUrl();
      setState(() => _isRelayUrlModified = false);
    } else {
      // Save custom relay URL
      await authService.setRelayUrl(newUrl);
      setState(() => _isRelayUrlModified = true);
    }

    // Reinitialize P2P with new relay URL
    final effectiveUrl = newUrl.isEmpty ? null : newUrl;
    // Not awaited: re-resolving relays takes seconds and the toast below
    // should not wait for it. The notifier catches and logs its own failures.
    unawaited(
      ref.read(p2pStatusNotifierProvider.notifier).reinitializeWithRelayUrl(
            effectiveUrl == defaultRelayUrl ? null : effectiveUrl,
          ),
    );

    if (mounted) {
      showToast(
        context,
        _isRelayUrlModified
            ? context.l10n.loginRelaySaved
            : context.l10n.loginRelayResetDone,
        kind: ToastKind.success,
      );
    }
  }

  void _resetRelayUrlToDefault() {
    setState(() {
      _relayUrlController.text = defaultRelayUrl;
    });
  }

  @override
  void dispose() {
    _claimCodeController.removeListener(_onClaimCodeChanged);
    _animationController.dispose();
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _claimCodeController.dispose();
    _relayUrlController.dispose();
    _totpController.dispose();
    _serverUrlFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _claimCodeFocus.dispose();
    _relayUrlFocus.dispose();
    _totpFocus.dispose();
    _tvSettingsFocusNode.dispose();
    _closeSettingsFocusNode.dispose();
    _settingsOverlayScopeNode.dispose();
    _scannerController?.dispose();
    super.dispose();
  }

  void _openQrScanner() {
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
    setState(() => _showQrScanner = true);
  }

  void _closeQrScanner() {
    _scannerController?.dispose();
    _scannerController = null;
    setState(() => _showQrScanner = false);
  }

  void _handleQrCodeDetected(BarcodeCapture capture) {
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    // Try to parse as QR pairing data
    final qrData = QrPairingData.tryParse(barcode.rawValue!);
    if (qrData == null) {
      // Not a valid Mydia QR code - show error briefly and continue scanning
      showToast(
        context,
        context.l10n.loginInvalidQr,
        kind: ToastKind.error,
      );
      return;
    }

    // Valid QR - close scanner, show detected code, and pair
    _closeQrScanner();

    // Populate the claim code field to show the detected code
    _claimCodeController.text = qrData.claimCode;

    _pairWithQrData(qrData);
  }

  /// Finishes a successful pairing or login by entering the app.
  ///
  /// When the credentials could not be written to durable storage, the user
  /// has to acknowledge that before going in. This is the only moment they are
  /// told, because the login screen is gone immediately afterwards.
  Future<void> _completePairing() async {
    if (!mounted) return;

    final state = ref.read(loginControllerProvider);
    if (!state.success) return;

    if (state.credentialsNotPersisted) {
      await showStorageUnavailableDialog(context);
      if (!mounted) return;
    }

    final added = state.addedSource;
    // A new server opens on its own page.
    context.go(added == null ? '/' : sourceHomeLocation(added));
  }

  Future<void> _pairWithQrData(QrPairingData qrData) async {
    final controller = ref.read(loginControllerProvider.notifier);
    await controller.pairWithQrCode(qrData,
        reauthAccountId: widget.reauthAccountId);

    await _completePairing();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final controller = ref.read(loginControllerProvider.notifier);
    await controller.login(
      _serverUrlController.text.trim(),
      _usernameController.text.trim(),
      _passwordController.text,
      reauthAccountId: widget.reauthAccountId,
    );

    await _completePairing();
  }

  Future<void> _handleClaimCodeSubmit() async {
    final code = _claimCodeController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    final controller = ref.read(loginControllerProvider.notifier);
    // No custom relay URL: the claim code resolves through the relay API and
    // iroh's default discovery.
    await controller.pairWithClaimCode(code,
        reauthAccountId: widget.reauthAccountId);

    await _completePairing();
  }

  void _handleTvCharacterPressed(String char) {
    if (_claimCodeController.text.length < 6) {
      final updated = _claimCodeController.text + char;
      setState(() {
        _claimCodeController.text = updated;
      });
      if (updated.length == 6) {
        _handleClaimCodeSubmit();
      }
    }
  }

  void _handleTvDeletePressed() {
    final text = _claimCodeController.text;
    if (text.isNotEmpty) {
      setState(() {
        _claimCodeController.text = text.substring(0, text.length - 1);
      });
    }
  }

  void _handleTvClearPressed() {
    setState(() {
      _claimCodeController.clear();
    });
  }

  void _openAdvancedSettings() {
    setState(() => _showAdvancedSettings = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showAdvancedSettings) return;
      _closeSettingsFocusNode.requestFocus();
    });
  }

  void _closeAdvancedSettings() {
    setState(() => _showAdvancedSettings = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _showAdvancedSettings) return;
      if (InputCapabilities.directionalPrimary &&
          _tvSettingsFocusNode.canRequestFocus) {
        _tvSettingsFocusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // A challenge that goes from set to cleared without the Back button
    // (e.g. "Sign-in expired" during submitTotpCode) drops the user back on
    // the password step. Without this, the stale code stays in the field
    // and is prefilled on the next challenge.
    ref.listen(loginControllerProvider, (previous, next) {
      if (previous?.totpChallenge != null && next.totpChallenge == null) {
        _totpController.clear();
      }
    });

    final loginState = ref.watch(loginControllerProvider);
    final size = MediaQuery.of(context).size;
    final isCompact = size.height < 700;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && InputCapabilities.directionalPrimary) {
          if (event.logicalKey == LogicalKeyboardKey.escape ||
              event.logicalKey == LogicalKeyboardKey.goBack) {
            if (_showAdvancedSettings) {
              _closeAdvancedSettings();
              return KeyEventResult.handled;
            }
            if (!loginState.isLoading &&
                !_showDirectConnection &&
                _claimCodeController.text.isNotEmpty) {
              _handleTvDeletePressed();
              return KeyEventResult.handled;
            }
          }
        }
        return KeyEventResult.ignored;
      },
      child: PopScope(
        canPop: !_showAdvancedSettings &&
            (!InputCapabilities.directionalPrimary ||
                loginState.isLoading ||
                _showDirectConnection ||
                _claimCodeController.text.isEmpty),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_showAdvancedSettings) {
            _closeAdvancedSettings();
          } else if (!loginState.isLoading &&
              !_showDirectConnection &&
              _claimCodeController.text.isNotEmpty) {
            _handleTvDeletePressed();
          }
        },
        // No `Scaffold.appBar` here (the card layout has nowhere to put one),
        // so the window's traffic-light band is drawn by an overlaid
        // `WindowTitleRow` instead, below. The `Scaffold` itself is NOT under
        // `removeBand`: the QR scanner and advanced-settings overlays are its
        // direct `Stack` siblings, and each needs the real band still present
        // in its `MediaQuery` so its own `SafeArea` keeps their close buttons
        // clear of the traffic lights. Only the centred card's `SafeArea`
        // removes the band, since that card's own row already reserves the
        // strip.
        child: Scaffold(
          body: Container(
            width: size.width,
            height: size.height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  palette.background,
                  const Color(0xFF0F172A),
                  const Color(0xFF0A0F1D),
                ],
              ),
            ),
            child: Stack(
              children: [
                _buildBackgroundDecoration(),
                ExcludeFocus(
                  excluding: _showAdvancedSettings || _showQrScanner,
                  child: WindowChromeInsets.removeBand(
                    child: SafeArea(
                      child: Center(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: isCompact ? 16 : 24,
                          ),
                          child: FadeTransition(
                            opacity: _fadeAnimation,
                            child: SlideTransition(
                              position: _slideAnimation,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (!InputCapabilities
                                      .directionalPrimary) ...[
                                    _buildLogo(isCompact),
                                    SizedBox(height: isCompact ? 24 : 32),
                                  ],
                                  _buildContent(loginState, isCompact),
                                  const SizedBox(height: 16),
                                  _buildFooter(loginState),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Mounted before the overlays below, so a click anywhere the
                // overlays paint (including their own close buttons, in the
                // same corner the drag band's hit-test would otherwise claim)
                // lands on the overlay and not on this empty-space drag
                // handle. No signed-in device to cast to yet, so no cast
                // button. Nothing else sits under the traffic lights either:
                // this is just enough to make the window draggable and to
                // keep the corners clear, matching every other screen now
                // that Linux has no other drag area at all.
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: WindowTitleRow(showCast: false),
                ),
                // Pushed (Add a server > Mydia), this screen has no app bar to
                // carry a back button, and iOS has no system back. The D-pad
                // tier has a hardware back key, and the button would only be
                // one more stop for focus.
                if (!InputCapabilities.directionalPrimary &&
                    Navigator.canPop(context))
                  Positioned(
                    top: 0,
                    left: 0,
                    child: ExcludeFocus(
                      excluding: _showAdvancedSettings || _showQrScanner,
                      child: const SafeArea(
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: BackButton(
                            key: Key('login-back'),
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_showQrScanner) _buildQrScannerOverlay(),
                if (_showAdvancedSettings) _buildAdvancedSettingsOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(LoginState loginState, bool isCompact) {
    // The claim code card contains the direct connection form as an
    // expandable section.
    final card = InputCapabilities.directionalPrimary
        ? _buildTvPairingLayout(loginState, isCompact)
        : _buildClaimCodeCard(loginState, isCompact);
    // The way in for someone with only a Plex, Jellyfin or Stash server.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        card,
        if (widget.reauthAccountId == null) ...const [
          SizedBox(height: 16),
          ConnectOtherServerButton(),
          ShowHiddenSourcesButton(),
        ],
      ],
    );
  }

  Widget _buildBackgroundDecoration() {
    final palette = context.palette;
    return Stack(
      children: [
        Positioned(
          top: -80,
          right: -80,
          child: Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  palette.primary.withValues(alpha: 0.12),
                  palette.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -100,
          left: -80,
          child: Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  palette.primary.withValues(alpha: 0.08),
                  palette.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQrScannerOverlay() {
    final palette = context.palette;
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.9),
        child: SafeArea(
          child: Column(
            children: [
              // Header with close button
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _closeQrScanner,
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    Expanded(
                      child: Text(
                        context.l10n.loginScanQrCode,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 48), // Balance the close button
                  ],
                ),
              ),
              // Scanner
              Expanded(
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(
                      maxWidth: 300,
                      maxHeight: 300,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: palette.primary,
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: _scannerController != null
                          ? MobileScanner(
                              controller: _scannerController!,
                              onDetect: _handleQrCodeDetected,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
              // Instructions
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.l10n.loginScanQrInstructions,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLogo(bool isCompact) {
    final logoSize = isCompact ? 56.0 : 64.0;
    final iconSize = isCompact ? 32.0 : 36.0;
    final titleSize = isCompact ? 28.0 : 32.0;
    final palette = context.palette;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: logoSize,
          height: logoSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [palette.primary, palette.primaryFocus],
            ),
            boxShadow: [
              BoxShadow(
                color: palette.primary.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(
            Icons.play_circle_filled_rounded,
            size: iconSize,
            color: Colors.white,
          ),
        ),
        SizedBox(height: isCompact ? 12 : 16),
        // The pill sits inline so it adds no height: the form below must
        // stay on screen on short windows.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _isAdding
                    ? context.l10n.loginAddServerTitle
                    : 'Mydia Player', // l10n-ignore: product name
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.bold,
                  color: palette.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const ChannelBadge(),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          context.l10n.loginTagline,
          style: TextStyle(
            fontSize: 13,
            color: palette.textSecondary.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  // ===== TV TWO-COLUMN LAYOUT =====
  Widget _buildTvPairingLayout(LoginState loginState, bool isCompact) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 1020),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: _buildTvLeftCard(loginState, isCompact),
          ),
          const SizedBox(width: 20),
          Expanded(
            flex: 6,
            child: _buildTvRightCard(loginState),
          ),
        ],
      ),
    );
  }

  Widget _buildTvLeftCard(LoginState loginState, bool isCompact) {
    return GlassSurface.modal(
      child: Padding(
        padding: EdgeInsets.all(isCompact ? 16 : 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildTvHeader(),
            SizedBox(height: isCompact ? 12 : 16),
            _buildSegmentedControl(loginState),
            SizedBox(height: isCompact ? 14 : 18),
            if (!_showDirectConnection) ...[
              _buildTvInstructions(),
              SizedBox(height: isCompact ? 14 : 18),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: PinCodeDisplay(
                  code: _claimCodeController.text,
                  hasError: loginState.error != null &&
                      loginState.mode != ConnectionMode.direct,
                  isLoading: loginState.isLoading,
                ),
              ),
              if (loginState.pairingStep != null &&
                  loginState.claimCodeStatus != ClaimCodeStatus.error) ...[
                const SizedBox(height: 12),
                _buildTvLoadingIndicator(loginState),
              ],
              if (loginState.error != null &&
                  loginState.mode != ConnectionMode.direct) ...[
                const SizedBox(height: 12),
                _buildErrorMessage(loginState.error!),
              ],
              SizedBox(height: isCompact ? 16 : 20),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildTvConnectButton(loginState),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: _buildTvClearButton(loginState),
                  ),
                ],
              ),
            ] else ...[
              _buildDirectConnectionContent(loginState, isCompact),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTvRightCard(LoginState loginState) {
    return GlassSurface.modal(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: TvKeypad(
          enabled: !loginState.isLoading && !_showDirectConnection,
          onCharacterPressed: _handleTvCharacterPressed,
          onDeletePressed: _handleTvDeletePressed,
          onClearPressed: _handleTvClearPressed,
        ),
      ),
    );
  }

  Widget _buildTvHeader() {
    final palette = context.palette;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [palette.primary, palette.primaryFocus],
            ),
            boxShadow: [
              BoxShadow(
                color: palette.primary.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.play_circle_filled_rounded,
            size: 24,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _isAdding
                          ? context.l10n.loginAddServerTitle
                          : 'Mydia Player', // l10n-ignore: product name
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: palette.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const ChannelBadge(),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _showDirectConnection
                    ? context.l10n.loginDirectSubtitle
                    : context.l10n.loginTvPairSubtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textSecondary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        FocusHighlight(
          focusNode: _tvSettingsFocusNode,
          onActivate: _openAdvancedSettings,
          borderRadius: BorderRadius.circular(8),
          child: IconButton(
            onPressed: _openAdvancedSettings,
            icon: const Icon(Icons.settings_outlined, size: 20),
            color: palette.textSecondary,
            tooltip: context.l10n.loginNetworkSettingsTooltip,
            style: IconButton.styleFrom(
              backgroundColor: palette.surfaceVariant.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTvInstructions() {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceVariant.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: palette.border.withValues(alpha: 0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInstructionStep(1, context.l10n.loginTvStepOpenMydia),
          const SizedBox(height: 6),
          _buildInstructionStep(2, context.l10n.loginTvStepOpenDevices),
          const SizedBox(height: 6),
          _buildInstructionStep(3, context.l10n.loginTvStepEnterCode),
        ],
      ),
    );
  }

  Widget _buildInstructionStep(int number, String text) {
    final palette = context.palette;
    return Row(
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: palette.primary.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: palette.primary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: palette.textSecondary.withValues(alpha: 0.85),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTvLoadingIndicator(LoginState loginState) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (loginState.isLoading) ...[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: palette.primary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              loginState.pairingStep == null
                  ? ''
                  : context.l10n.pairingStepText(loginState.pairingStep!),
              style: TextStyle(
                color: palette.primary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTvConnectButton(LoginState loginState) {
    final palette = context.palette;
    final canConnect =
        _claimCodeController.text.length == 6 && !loginState.isLoading;
    return FocusHighlight(
      onActivate: canConnect ? _handleClaimCodeSubmit : null,
      borderRadius: BorderRadius.circular(10),
      child: ElevatedButton(
        onPressed: canConnect ? _handleClaimCodeSubmit : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: palette.primary.withValues(alpha: 0.4),
          disabledForegroundColor: Colors.white.withValues(alpha: 0.4),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: loginState.isLoading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    context.l10n.loginConnect,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.link_rounded, size: 18),
                ],
              ),
      ),
    );
  }

  Widget _buildTvClearButton(LoginState loginState) {
    final palette = context.palette;
    final canClear =
        _claimCodeController.text.isNotEmpty && !loginState.isLoading;
    return FocusHighlight(
      onActivate: canClear ? _handleTvClearPressed : null,
      borderRadius: BorderRadius.circular(10),
      child: OutlinedButton(
        onPressed: canClear ? _handleTvClearPressed : null,
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.textSecondary,
          disabledForegroundColor: palette.textDisabled,
          side: BorderSide(
            color: palette.border.withValues(alpha: 0.3),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.refresh_rounded, size: 16),
            const SizedBox(width: 6),
            Text(
              context.l10n.loginClear,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }

  // ===== LOGIN CARD =====
  Widget _buildClaimCodeCard(LoginState loginState, bool isCompact) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      child: GlassSurface.modal(
        child: Padding(
          padding: EdgeInsets.all(isCompact ? 20 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildCardHeader(isCompact),
              SizedBox(height: isCompact ? 14 : 18),
              _buildSegmentedControl(loginState),
              SizedBox(height: isCompact ? 16 : 20),
              if (!_showDirectConnection)
                _buildClaimCodeContent(loginState, isCompact)
              else
                _buildDirectConnectionContent(loginState, isCompact),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardHeader(bool isCompact) {
    final palette = context.palette;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.l10n.loginConnectTitle,
                style: TextStyle(
                  fontSize: isCompact ? 18 : 20,
                  fontWeight: FontWeight.w600,
                  color: palette.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _showDirectConnection
                    ? context.l10n.loginDirectSubtitle
                    : context.l10n.loginPairSubtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: palette.textSecondary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: _openAdvancedSettings,
          icon: const Icon(Icons.settings_outlined, size: 20),
          color: palette.textSecondary,
          tooltip: context.l10n.loginNetworkSettingsTooltip,
          style: IconButton.styleFrom(
            backgroundColor: palette.surfaceVariant.withValues(alpha: 0.3),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSegmentedControl(LoginState loginState) {
    final palette = context.palette;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.surfaceVariant.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: palette.border.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildSegmentTab(
              title: context.l10n.loginQuickPair,
              icon: Icons.qr_code_rounded,
              isSelected: !_showDirectConnection,
              onTap: loginState.isLoading
                  ? null
                  : () {
                      setState(() => _showDirectConnection = false);
                      ref
                          .read(loginControllerProvider.notifier)
                          .setMode(ConnectionMode.claimCode);
                    },
            ),
          ),
          Expanded(
            child: _buildSegmentTab(
              title: context.l10n.loginDirectServer,
              icon: Icons.dns_outlined,
              isSelected: _showDirectConnection,
              onTap: loginState.isLoading
                  ? null
                  : () {
                      setState(() => _showDirectConnection = true);
                      ref
                          .read(loginControllerProvider.notifier)
                          .setMode(ConnectionMode.direct);
                    },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentTab({
    required String title,
    required IconData icon,
    required bool isSelected,
    required VoidCallback? onTap,
  }) {
    final palette = context.palette;
    return FocusHighlight(
      onActivate: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(7)),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeInOut,
          alignment: Alignment.center,
          height: double.infinity,
          decoration: BoxDecoration(
            color: isSelected ? palette.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: palette.primary.withValues(alpha: 0.3),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: isSelected ? Colors.white : palette.textSecondary,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                    color: isSelected ? Colors.white : palette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClaimCodeContent(LoginState loginState, bool isCompact) {
    final palette = context.palette;
    final isMobile = defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final offersQr = LoginScreen.offersQrScan(
      directionalPrimary: InputCapabilities.directionalPrimary,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildClaimCodeInput(loginState),
        if (offersQr) ...[
          SizedBox(height: isCompact ? 12 : 14),
          SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              onPressed: loginState.isLoading ? null : _openQrScanner,
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
              label: Text(
                isMobile
                    ? context.l10n.loginScanQrCode
                    : context.l10n.loginScanQrWithCamera,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.primary,
                side: BorderSide(
                  color: palette.primary.withValues(alpha: 0.4),
                  width: 1.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
        if (loginState.pairingStep != null &&
            loginState.claimCodeStatus != ClaimCodeStatus.error) ...[
          const SizedBox(height: 14),
          _buildProgressIndicator(loginState),
        ],
        if (loginState.error != null &&
            loginState.mode != ConnectionMode.direct) ...[
          const SizedBox(height: 14),
          _buildErrorMessage(loginState.error!),
        ],
        SizedBox(height: isCompact ? 16 : 20),
        _buildClaimCodeButton(loginState),
      ],
    );
  }

  Widget _buildDirectConnectionContent(LoginState loginState, bool isCompact) {
    return _buildDirectConnectionForm(loginState, isCompact);
  }

  Widget _buildDirectConnectionForm(LoginState loginState, bool isCompact) {
    final palette = context.palette;
    if (loginState.totpChallenge != null) {
      return _buildTotpForm(loginState, isCompact);
    }
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTextField(
            controller: _serverUrlController,
            focusNode: _serverUrlFocus,
            label: context.l10n.loginServerUrlLabel,
            hint: 'https://mydia.example.com',
            icon: Icons.dns_outlined,
            enabled: !loginState.isLoading,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            onFieldSubmitted: (_) => _usernameFocus.requestFocus(),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return context.l10n.loginServerUrlRequired;
              }
              if (!value.startsWith('http://') &&
                  !value.startsWith('https://')) {
                return context.l10n.loginServerUrlScheme;
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _usernameController,
            focusNode: _usernameFocus,
            label: context.l10n.loginUsernameLabel,
            icon: Icons.person_outline_rounded,
            enabled: !loginState.isLoading,
            textInputAction: TextInputAction.next,
            onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return context.l10n.loginUsernameRequired;
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          _buildTextField(
            controller: _passwordController,
            focusNode: _passwordFocus,
            label: context.l10n.loginPasswordLabel,
            icon: Icons.lock_outline_rounded,
            enabled: !loginState.isLoading,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _handleLogin(),
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: palette.textSecondary,
                size: 18,
              ),
              onPressed: () {
                setState(() => _obscurePassword = !_obscurePassword);
              },
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return context.l10n.loginPasswordRequired;
              }
              return null;
            },
          ),
          if (loginState.error != null &&
              loginState.mode == ConnectionMode.direct) ...[
            const SizedBox(height: 14),
            _buildErrorMessage(loginState.error!),
          ],
          SizedBox(height: isCompact ? 20 : 24),
          _buildLoginButton(loginState),
        ],
      ),
    );
  }

  Widget _buildTotpForm(LoginState loginState, bool isCompact) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.loginTotpTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          context.l10n.loginTotpBody,
          style: TextStyle(fontSize: 13, color: palette.textSecondary),
        ),
        const SizedBox(height: 14),
        TextFormField(
          key: const Key('totp-code-field'),
          controller: _totpController,
          focusNode: _totpFocus,
          autofocus: true,
          enabled: !loginState.isLoading,
          autofillHints: const [AutofillHints.oneTimeCode],
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          textAlign: TextAlign.center,
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) => _handleTotpSubmit(),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: palette.textPrimary,
            letterSpacing: 3,
          ),
          decoration: InputDecoration(
            labelText: context.l10n.loginTotpCodeLabel,
            filled: true,
            fillColor: palette.surfaceVariant.withValues(alpha: 0.4),
          ),
        ),
        if (loginState.error != null) ...[
          const SizedBox(height: 14),
          _buildErrorMessage(loginState.error!),
        ],
        SizedBox(height: isCompact ? 20 : 24),
        SizedBox(
          height: 44,
          child: ElevatedButton(
            key: const Key('totp-verify-button'),
            onPressed: loginState.isLoading ? null : _handleTotpSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: palette.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: loginState.isLoading
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(context.l10n.loginTotpVerify),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('totp-back-button'),
          onPressed: loginState.isLoading
              ? null
              : () {
                  _totpController.clear();
                  ref.read(loginControllerProvider.notifier).cancelTotp();
                },
          child: Text(context.l10n.commonBack),
        ),
      ],
    );
  }

  Future<void> _handleTotpSubmit() async {
    final code = _totpController.text.trim();
    if (code.isEmpty) return;

    await ref
        .read(loginControllerProvider.notifier)
        .submitTotpCode(code, reauthAccountId: widget.reauthAccountId);
    await _completePairing();
  }

  Widget _buildClaimCodeInput(LoginState loginState) {
    final palette = context.palette;
    return TextFormField(
      controller: _claimCodeController,
      focusNode: _claimCodeFocus,
      autofocus: InputCapabilities.directionalPrimary,
      enabled: !loginState.isLoading,
      textAlign: TextAlign.center,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
        LengthLimitingTextInputFormatter(8),
        UpperCaseTextFormatter(),
      ],
      onFieldSubmitted: (_) => _handleClaimCodeSubmit(),
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: palette.textPrimary,
        letterSpacing: 4,
      ),
      decoration: InputDecoration(
        hintText: 'ABC123', // l10n-ignore: sample claim code
        hintStyle: TextStyle(
          color: palette.textDisabled.withValues(alpha: 0.4),
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: 4,
        ),
        filled: true,
        fillColor: palette.surfaceVariant.withValues(alpha: 0.4),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        suffixIcon: IconButton(
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          color: palette.textSecondary,
          tooltip: context.l10n.loginPasteClaimCode,
          onPressed: loginState.isLoading
              ? null
              : () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null && data!.text!.isNotEmpty) {
                    final cleanText = data.text!
                        .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
                        .toUpperCase();
                    _claimCodeController.text = cleanText;
                    if (cleanText.length >= 6) {
                      await _handleClaimCodeSubmit();
                    }
                  }
                },
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: palette.border.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: palette.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildProgressIndicator(LoginState loginState) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: palette.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.primary.withValues(alpha: 0.2)),
      ),
      child: Text(
        loginState.pairingStep == null
            ? ''
            : context.l10n.pairingStepText(loginState.pairingStep!),
        style: TextStyle(
          color: palette.primary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildClaimCodeButton(LoginState loginState) {
    final palette = context.palette;
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loginState.isLoading ? null : _handleClaimCodeSubmit,
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: palette.primary.withValues(alpha: 0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: loginState.isLoading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    context.l10n.loginConnect,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.link_rounded, size: 18),
                ],
              ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required IconData icon,
    required bool enabled,
    required String? Function(String?) validator,
    String? hint,
    bool obscureText = false,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    Widget? suffixIcon,
    void Function(String)? onFieldSubmitted,
  }) {
    final palette = context.palette;
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      style: TextStyle(fontSize: 14, color: palette.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(
          fontSize: 13,
          color: palette.textSecondary.withValues(alpha: 0.8),
        ),
        hintStyle: TextStyle(
          color: palette.textDisabled.withValues(alpha: 0.5),
          fontSize: 13,
        ),
        prefixIcon: Icon(icon, color: palette.textSecondary, size: 18),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: palette.surfaceVariant.withValues(alpha: 0.4),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: palette.border.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: palette.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.error, width: 1.5),
        ),
        errorStyle: const TextStyle(color: AppColors.error, fontSize: 11),
      ),
    );
  }

  Widget _buildErrorMessage(LoginFailure error) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppColors.error, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.l10n.loginFailure(error),
              style: const TextStyle(
                color: AppColors.error,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginButton(LoginState loginState) {
    final palette = context.palette;
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loginState.isLoading ? null : _handleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: palette.primary.withValues(alpha: 0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: loginState.isLoading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    context.l10n.loginSignIn,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
      ),
    );
  }

  Widget _buildFooter(LoginState loginState) {
    final palette = context.palette;
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p2pStatus.isInitialized) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p2pStatus.isRelayConnected
                  ? AppColors.success
                  : AppColors.warning,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            p2pStatus.isRelayConnected
                ? context.l10n.loginP2pReady
                : context.l10n.loginP2pConnecting,
            style: TextStyle(
              fontSize: 11,
              color: palette.textSecondary.withValues(alpha: 0.5),
            ),
          ),
          Text(
            '  •  ',
            style: TextStyle(
              fontSize: 11,
              color: palette.textSecondary.withValues(alpha: 0.3),
            ),
          ),
        ],
        Icon(
          Icons.lock_rounded,
          size: 11,
          color: palette.textSecondary.withValues(alpha: 0.4),
        ),
        const SizedBox(width: 4),
        Text(
          context.l10n.loginEncrypted,
          style: TextStyle(
            fontSize: 11,
            color: palette.textSecondary.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }

  Widget _buildAdvancedSettingsOverlay() {
    final palette = context.palette;
    return Positioned.fill(
      child: FocusScope(
        node: _settingsOverlayScopeNode,
        child: GestureDetector(
          onTap: _closeAdvancedSettings,
          child: Container(
            color: Colors.black.withValues(alpha: 0.7),
            child: Center(
              child: GestureDetector(
                onTap: () {}, // Prevent tap from closing
                child: Container(
                  margin: const EdgeInsets.all(24),
                  constraints: const BoxConstraints(maxWidth: 400),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: palette.border.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.settings_outlined,
                              color: palette.textSecondary,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                context.l10n.loginAdvancedSettings,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: palette.textPrimary,
                                ),
                              ),
                            ),
                            FocusHighlight(
                              focusNode: _closeSettingsFocusNode,
                              onActivate: _closeAdvancedSettings,
                              borderRadius: BorderRadius.circular(8),
                              child: IconButton(
                                onPressed: _closeAdvancedSettings,
                                tooltip:
                                    context.l10n.loginCloseAdvancedSettings,
                                icon: Icon(
                                  Icons.close,
                                  color: palette.textSecondary,
                                  size: 20,
                                ),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        height: 1,
                        color: palette.border.withValues(alpha: 0.15),
                      ),
                      // Content
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.loginRelayUrlLabel,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: palette.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: palette.surfaceVariant
                                    .withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: palette.border.withValues(alpha: 0.1),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    size: 14,
                                    color: palette.textSecondary
                                        .withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      context.l10n.loginRelayUrlHelp,
                                      style: TextStyle(
                                        fontSize: 11,
                                        height: 1.35,
                                        color: palette.textSecondary
                                            .withValues(alpha: 0.75),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _relayUrlController,
                              focusNode: _relayUrlFocus,
                              style: TextStyle(
                                fontSize: 13,
                                color: palette.textPrimary,
                              ),
                              decoration: InputDecoration(
                                hintText: defaultRelayUrl,
                                hintStyle: TextStyle(
                                  color: palette.textDisabled
                                      .withValues(alpha: 0.5),
                                  fontSize: 13,
                                ),
                                filled: true,
                                fillColor: palette.surfaceVariant
                                    .withValues(alpha: 0.4),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide.none,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(
                                    color:
                                        palette.border.withValues(alpha: 0.15),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(
                                    color: palette.primary,
                                    width: 1.5,
                                  ),
                                ),
                                suffixIcon: _relayUrlController.text !=
                                        defaultRelayUrl
                                    ? IconButton(
                                        onPressed: _resetRelayUrlToDefault,
                                        icon: Icon(
                                          Icons.refresh,
                                          size: 18,
                                          color: palette.textSecondary,
                                        ),
                                        tooltip:
                                            context.l10n.loginRelayResetTooltip,
                                      )
                                    : null,
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            if (_isRelayUrlModified) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    size: 12,
                                    color:
                                        palette.primary.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      context.l10n.loginRelayCustomInUse,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: palette.primary
                                            .withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      Container(
                        height: 1,
                        color: palette.border.withValues(alpha: 0.15),
                      ),
                      // Actions
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _closeAdvancedSettings,
                              child: Text(context.l10n.commonCancel),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: () {
                                _saveRelayUrl();
                                _closeAdvancedSettings();
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: palette.primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Text(
                                context.l10n.loginSave,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Text input formatter that converts text to uppercase.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
