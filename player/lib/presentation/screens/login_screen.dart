import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/auth/auth_service.dart';
import '../../core/p2p/p2p_service.dart' show defaultRelayUrl;
import '../../core/theme/colors.dart';
import '../widgets/glass_surface.dart';
import '../widgets/storage_unavailable_dialog.dart';
import '../widgets/update_required_dialog.dart';
import 'login/login_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _claimCodeController = TextEditingController();
  final _relayUrlController = TextEditingController();
  final _serverUrlFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _claimCodeFocus = FocusNode();
  final _relayUrlFocus = FocusNode();

  bool _isLoadingSavedUrl = true;
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
    _loadSavedServerUrl();
    _loadSavedRelayUrl();
    _setupAnimations();
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

  Future<void> _loadSavedServerUrl() async {
    final authService = ref.read(authServiceProvider);
    final savedUrl = await authService.getServerUrl();
    if (mounted) {
      setState(() {
        if (savedUrl != null) {
          _serverUrlController.text = savedUrl;
        }
        _isLoadingSavedUrl = false;
      });
    }
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
    ref.read(p2pStatusNotifierProvider.notifier).reinitializeWithRelayUrl(
          effectiveUrl == defaultRelayUrl ? null : effectiveUrl,
        );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isRelayUrlModified
                ? 'Custom relay URL saved'
                : 'Relay URL reset to default',
          ),
          duration: const Duration(seconds: 2),
        ),
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
    _animationController.dispose();
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _claimCodeController.dispose();
    _relayUrlController.dispose();
    _serverUrlFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _claimCodeFocus.dispose();
    _relayUrlFocus.dispose();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid QR code. Please scan a Mydia pairing code.'),
          duration: Duration(seconds: 2),
        ),
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

    context.go('/');
  }

  Future<void> _pairWithQrData(QrPairingData qrData) async {
    final controller = ref.read(loginControllerProvider.notifier);
    await controller.pairWithQrCode(qrData);

    await _completePairing();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final controller = ref.read(loginControllerProvider.notifier);
    await controller.login(
      _serverUrlController.text.trim(),
      _usernameController.text.trim(),
      _passwordController.text,
    );

    await _completePairing();
  }

  Future<void> _handleClaimCodeSubmit() async {
    final code = _claimCodeController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    final controller = ref.read(loginControllerProvider.notifier);
    // Custom relay URL is no longer needed - we use IPFS DHT bootstrap
    await controller.pairWithClaimCode(code);

    await _completePairing();
  }

  @override
  Widget build(BuildContext context) {
    final loginState = ref.watch(loginControllerProvider);
    final size = MediaQuery.of(context).size;
    final isCompact = size.height < 700;

    // Listen for update required errors and show dialog
    ref.listen<LoginState>(
      loginControllerProvider,
      (previous, next) {
        if (next.updateRequiredError != null &&
            previous?.updateRequiredError == null) {
          showUpdateRequiredDialog(context, next.updateRequiredError!)
              .then((_) {
            if (mounted) {
              ref
                  .read(loginControllerProvider.notifier)
                  .clearUpdateRequiredError();
            }
          });
        }
      },
    );

    return Scaffold(
      body: Container(
        width: size.width,
        height: size.height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.background,
              Color(0xFF0E1828),
              AppColors.background,
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: Stack(
          children: [
            _buildBackgroundDecoration(),
            SafeArea(
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
                          _buildLogo(isCompact),
                          SizedBox(height: isCompact ? 24 : 32),
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
            if (_showQrScanner) _buildQrScannerOverlay(),
            if (_showAdvancedSettings) _buildAdvancedSettingsOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(LoginState loginState, bool isCompact) {
    // Always show the claim code card which now contains
    // the direct connection form as an expandable section
    return _buildClaimCodeCard(loginState, isCompact);
  }

  Widget _buildBackgroundDecoration() {
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
                  AppColors.primary.withValues(alpha: 0.12),
                  AppColors.primary.withValues(alpha: 0.0),
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
                  AppColors.primary.withValues(alpha: 0.08),
                  AppColors.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQrScannerOverlay() {
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
                    const Expanded(
                      child: Text(
                        'Scan QR Code',
                        textAlign: TextAlign.center,
                        style: TextStyle(
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
                        color: AppColors.primary,
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
                  'Point your camera at the QR code shown on your Mydia server',
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: logoSize,
          height: logoSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.primary, AppColors.primaryFocus],
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.25),
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
        Text(
          'Mydia Player',
          style: TextStyle(
            fontSize: titleSize,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Stream your media library',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.textSecondary.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  // ===== LOGIN CARD =====
  Widget _buildClaimCodeCard(LoginState loginState, bool isCompact) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      child: GlassSurface.modal(
        child: Padding(
          padding: EdgeInsets.all(isCompact ? 20 : 24),
          child: _showDirectConnection
              ? _buildDirectConnectionContent(loginState, isCompact)
              : _buildClaimCodeContent(loginState, isCompact),
        ),
      ),
    );
  }

  Widget _buildClaimCodeContent(LoginState loginState, bool isCompact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Title
        Text(
          'Connect to Server',
          style: TextStyle(
            fontSize: isCompact ? 18 : 20,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Scan QR code or enter claim code manually',
          style: TextStyle(
            fontSize: 12,
            color: AppColors.textSecondary.withValues(alpha: 0.7),
          ),
        ),
        SizedBox(height: isCompact ? 16 : 20),

        // Scan QR Code button
        SizedBox(
          height: 52,
          child: OutlinedButton.icon(
            onPressed: loginState.isLoading ? null : _openQrScanner,
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 22),
            label: const Text(
              'Scan QR Code',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(
                color: AppColors.primary.withValues(alpha: 0.5),
                width: 1.5,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),

        // "or" divider
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 1,
                  color: AppColors.border.withValues(alpha: 0.2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'or enter code',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary.withValues(alpha: 0.6),
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  height: 1,
                  color: AppColors.border.withValues(alpha: 0.2),
                ),
              ),
            ],
          ),
        ),

        // Claim code input (no server URL needed - relay looks it up)
        _buildClaimCodeInput(loginState),

        if (loginState.claimCodeMessage != null &&
            loginState.claimCodeStatus != ClaimCodeStatus.error) ...[
          const SizedBox(height: 16),
          _buildProgressIndicator(loginState),
        ],

        if (loginState.error != null &&
            loginState.mode != ConnectionMode.direct) ...[
          const SizedBox(height: 14),
          _buildErrorMessage(loginState.error!),
        ],

        SizedBox(height: isCompact ? 20 : 24),
        _buildClaimCodeButton(loginState),

        // Direct Connection link
        const SizedBox(height: 24),
        _buildDirectConnectionLink(loginState),
      ],
    );
  }

  Widget _buildDirectConnectionLink(LoginState loginState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Divider with "or"
        Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'or',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary.withValues(alpha: 0.6),
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 1,
                color: AppColors.border.withValues(alpha: 0.2),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Direct Connection button
        GestureDetector(
          onTap: loginState.isLoading
              ? null
              : () {
                  setState(() => _showDirectConnection = true);
                  ref
                      .read(loginControllerProvider.notifier)
                      .setMode(ConnectionMode.direct);
                },
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.border.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.dns_outlined,
                    color: AppColors.textSecondary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Direct Connection',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Advanced: Enter server URL directly',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: AppColors.textSecondary.withValues(alpha: 0.6),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDirectConnectionContent(LoginState loginState, bool isCompact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Back button and title row
        Row(
          children: [
            GestureDetector(
              onTap: loginState.isLoading
                  ? null
                  : () {
                      setState(() => _showDirectConnection = false);
                      ref
                          .read(loginControllerProvider.notifier)
                          .setMode(ConnectionMode.claimCode);
                    },
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 18,
                  color: loginState.isLoading
                      ? AppColors.textDisabled
                      : AppColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Direct Connection',
                style: TextStyle(
                  fontSize: isCompact ? 18 : 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 44),
          child: Text(
            'Connect directly to your server',
            style: TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary.withValues(alpha: 0.7),
            ),
          ),
        ),
        SizedBox(height: isCompact ? 20 : 24),

        // Direct connection form
        _buildDirectConnectionForm(loginState, isCompact),
      ],
    );
  }

  Widget _buildDirectConnectionForm(LoginState loginState, bool isCompact) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isLoadingSavedUrl)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
              ),
            )
          else ...[
            _buildTextField(
              controller: _serverUrlController,
              focusNode: _serverUrlFocus,
              label: 'Server URL',
              hint: 'https://mydia.example.com',
              icon: Icons.dns_outlined,
              enabled: !loginState.isLoading,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) => _usernameFocus.requestFocus(),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a server URL';
                }
                if (!value.startsWith('http://') &&
                    !value.startsWith('https://')) {
                  return 'URL must start with http:// or https://';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            _buildTextField(
              controller: _usernameController,
              focusNode: _usernameFocus,
              label: 'Username',
              icon: Icons.person_outline_rounded,
              enabled: !loginState.isLoading,
              textInputAction: TextInputAction.next,
              onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a username';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            _buildTextField(
              controller: _passwordController,
              focusNode: _passwordFocus,
              label: 'Password',
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
                  color: AppColors.textSecondary,
                  size: 18,
                ),
                onPressed: () {
                  setState(() => _obscurePassword = !_obscurePassword);
                },
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter a password';
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
        ],
      ),
    );
  }

  Widget _buildClaimCodeInput(LoginState loginState) {
    return TextFormField(
      controller: _claimCodeController,
      focusNode: _claimCodeFocus,
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
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
        letterSpacing: 4,
      ),
      decoration: InputDecoration(
        hintText: 'ABC123',
        hintStyle: TextStyle(
          color: AppColors.textDisabled.withValues(alpha: 0.4),
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: 4,
        ),
        filled: true,
        fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.border.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildProgressIndicator(LoginState loginState) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
      ),
      child: Text(
        loginState.claimCodeMessage ?? '',
        style: const TextStyle(
          color: AppColors.primary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildClaimCodeButton(LoginState loginState) {
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loginState.isLoading ? null : _handleClaimCodeSubmit,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.5),
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
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Connect',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(Icons.link_rounded, size: 18),
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
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      validator: validator,
      style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(
          fontSize: 13,
          color: AppColors.textSecondary.withValues(alpha: 0.8),
        ),
        hintStyle: TextStyle(
          color: AppColors.textDisabled.withValues(alpha: 0.5),
          fontSize: 13,
        ),
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 18),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
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
            color: AppColors.border.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
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

  Widget _buildErrorMessage(String error) {
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
              error,
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
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loginState.isLoading ? null : _handleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.5),
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
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Sign in',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(width: 6),
                  Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
      ),
    );
  }

  Widget _buildFooter(LoginState loginState) {
    final showEncrypted = !_showDirectConnection ||
        loginState.mode == ConnectionMode.claimCode ||
        loginState.mode == ConnectionMode.selection;
    final icon = showEncrypted ? Icons.lock_rounded : Icons.shield_outlined;
    final text = showEncrypted ? 'End-to-end encrypted' : 'Secure connection';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 12,
              color: AppColors.textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(width: 4),
            Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildP2pStatus(),
      ],
    );
  }

  Widget _buildP2pStatus() {
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);

    // Don't show anything if not initialized yet
    if (!p2pStatus.isInitialized) {
      return const SizedBox.shrink();
    }

    // Get display relay URL
    final displayRelayUrl = p2pStatus.relayUrl ?? defaultRelayUrl;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Relay connection status indicator
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
              p2pStatus.isRelayConnected ? 'P2P Ready' : 'Connecting...',
              style: TextStyle(
                fontSize: 10,
                color: AppColors.textSecondary.withValues(alpha: 0.5),
              ),
            ),
            // Show connected peer count
            if (p2pStatus.connectedPeersCount > 0) ...[
              const SizedBox(width: 8),
              Icon(
                Icons.people_outline_rounded,
                size: 10,
                color: AppColors.textSecondary.withValues(alpha: 0.4),
              ),
              const SizedBox(width: 3),
              Text(
                '${p2pStatus.connectedPeersCount}',
                style: TextStyle(
                  fontSize: 10,
                  color: AppColors.textSecondary.withValues(alpha: 0.5),
                ),
              ),
            ],
            // Settings button
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => setState(() => _showAdvancedSettings = true),
              child: Icon(
                Icons.settings_outlined,
                size: 14,
                color: AppColors.textSecondary.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Show relay URL
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 10,
              color: AppColors.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(width: 4),
            Text(
              displayRelayUrl,
              style: TextStyle(
                fontSize: 9,
                color: AppColors.textSecondary.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAdvancedSettingsOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _showAdvancedSettings = false),
        child: Container(
          color: Colors.black.withValues(alpha: 0.7),
          child: Center(
            child: GestureDetector(
              onTap: () {}, // Prevent tap from closing
              child: Container(
                margin: const EdgeInsets.all(24),
                constraints: const BoxConstraints(maxWidth: 400),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.border.withValues(alpha: 0.2),
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
                          const Icon(
                            Icons.settings_outlined,
                            color: AppColors.textSecondary,
                            size: 20,
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Advanced Settings',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () =>
                                setState(() => _showAdvancedSettings = false),
                            icon: const Icon(
                              Icons.close,
                              color: AppColors.textSecondary,
                              size: 20,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      height: 1,
                      color: AppColors.border.withValues(alpha: 0.15),
                    ),
                    // Content
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Relay URL',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'The relay server used for P2P connections',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.textSecondary
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _relayUrlController,
                            focusNode: _relayUrlFocus,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textPrimary,
                            ),
                            decoration: InputDecoration(
                              hintText: defaultRelayUrl,
                              hintStyle: TextStyle(
                                color: AppColors.textDisabled
                                    .withValues(alpha: 0.5),
                                fontSize: 13,
                              ),
                              filled: true,
                              fillColor: AppColors.surfaceVariant
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
                                      AppColors.border.withValues(alpha: 0.15),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                  color: AppColors.primary,
                                  width: 1.5,
                                ),
                              ),
                              suffixIcon:
                                  _relayUrlController.text != defaultRelayUrl
                                      ? IconButton(
                                          onPressed: _resetRelayUrlToDefault,
                                          icon: const Icon(
                                            Icons.refresh,
                                            size: 18,
                                            color: AppColors.textSecondary,
                                          ),
                                          tooltip: 'Reset to default',
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
                                      AppColors.primary.withValues(alpha: 0.7),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Using custom relay URL',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: AppColors.primary
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
                      color: AppColors.border.withValues(alpha: 0.15),
                    ),
                    // Actions
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () =>
                                setState(() => _showAdvancedSettings = false),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: () {
                              _saveRelayUrl();
                              setState(() => _showAdvancedSettings = false);
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
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
                            child: const Text(
                              'Save',
                              style: TextStyle(
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
