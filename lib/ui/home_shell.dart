import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/app_controller.dart';
import '../core/models.dart';
import 'theme.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    if (controller.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final width = MediaQuery.sizeOf(context).width;
    final desktopLayout = width >= 820;
    final pages = <Widget>[
      _ConnectPage(controller: controller),
      _TransferPage(controller: controller),
      _HistoryPage(controller: controller),
    ];

    final body = Column(
      children: [
        _Header(controller: controller),
        if (controller.error != null) _ErrorBanner(message: controller.error!),
        Expanded(
          child: IndexedStack(index: _section, children: pages),
        ),
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: desktopLayout
            ? Row(
                children: [
                  _DesktopNavigation(
                    selected: _section,
                    onSelected: (value) => setState(() => _section = value),
                  ),
                  const VerticalDivider(width: 1, color: CastColors.border),
                  Expanded(child: body),
                ],
              )
            : body,
      ),
      bottomNavigationBar: desktopLayout
          ? null
          : NavigationBar(
              selectedIndex: _section,
              onDestinationSelected: (value) =>
                  setState(() => _section = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.link_rounded),
                  label: 'Connexion',
                ),
                NavigationDestination(
                  icon: Icon(Icons.swap_vert_circle_outlined),
                  label: 'Transferts',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_rounded),
                  label: 'Historique',
                ),
              ],
            ),
    );
  }
}

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      backgroundColor: CastColors.background,
      selectedIndex: selected,
      onDestinationSelected: onSelected,
      labelType: NavigationRailLabelType.all,
      leading: const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 28),
        child: _Logo(),
      ),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.link_rounded),
          label: Text('Connexion'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.swap_horiz_rounded),
          label: Text('Transferts'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.history_rounded),
          label: Text('Historique'),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final connected = controller.clientConnected || controller.hasInboundPeer;
    final peerName =
        controller.connectedPeer?.name ??
        controller.inboundPeers.firstOrNull?.name;
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: CastColors.border)),
      ),
      child: Row(
        children: [
          if (MediaQuery.sizeOf(context).width < 820) ...[
            const _Logo(),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'CastFlow',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                Text(
                  controller.identity?.name ?? 'Appareil',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: connected ? CastColors.green : CastColors.muted,
              shape: BoxShape.circle,
              boxShadow: connected
                  ? const [BoxShadow(color: CastColors.green, blurRadius: 8)]
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            connected ? peerName ?? 'Connecté' : 'Hors connexion',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (controller.clientConnected) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Déconnecter',
              onPressed: controller.disconnect,
              icon: const Icon(Icons.link_off_rounded),
            ),
          ],
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [CastColors.cyan, CastColors.blue],
        ),
        borderRadius: BorderRadius.circular(13),
      ),
      child: const Icon(Icons.bolt_rounded, color: CastColors.background),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: CastColors.red.withValues(alpha: .12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: CastColors.red, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message.replaceFirst('Bad state: ', ''),
              style: const TextStyle(color: CastColors.red),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectPage extends StatelessWidget {
  const _ConnectPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 960;
        final children = <Widget>[
          if (controller.isDesktop)
            Expanded(
              flex: wide ? 5 : 0,
              child: _ReceiveCard(controller: controller),
            ),
          if (controller.isDesktop && wide) const SizedBox(width: 18),
          Expanded(
            flex: wide ? 6 : 0,
            child: _ConnectCard(controller: controller),
          ),
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (controller.isDesktop) ...[
                      _ReceiveCard(controller: controller),
                      const SizedBox(height: 16),
                    ],
                    _ConnectCard(controller: controller),
                  ],
                ),
        );
      },
    );
  }
}

class _ReceiveCard extends StatelessWidget {
  const _ReceiveCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final url = controller.connectUrl;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(
              icon: Icons.download_rounded,
              title: 'Recevoir sur cet ordinateur',
              subtitle: 'Scannez le QR depuis le téléphone.',
            ),
            const SizedBox(height: 22),
            if (url != null)
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(10),
                  child: QrImageView(data: url, size: 210),
                ),
              ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                controller.pin,
                style: const TextStyle(
                  color: CastColors.cyan,
                  fontWeight: FontWeight.w800,
                  fontSize: 32,
                  letterSpacing: 7,
                ),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: controller.regeneratePin,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Nouveau PIN'),
              ),
            ),
            const Divider(color: CastColors.border, height: 28),
            _InfoRow(label: 'Adresse', value: controller.localAddress),
            _InfoRow(
              label: 'Port HTTP',
              value: '${controller.server?.httpPort ?? '—'}',
            ),
            _InfoRow(
              label: 'Dossier',
              value: controller.downloadDirectory ?? '—',
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectCard extends StatefulWidget {
  const _ConnectCard({required this.controller});

  final AppController controller;

  @override
  State<_ConnectCard> createState() => _ConnectCardState();
}

class _ConnectCardState extends State<_ConnectCard> {
  final _address = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _connectManual() async {
    if (_address.text.trim().isEmpty) return;
    setState(() => _busy = true);
    await widget.controller.connectManual(_address.text);
    if (mounted) setState(() => _busy = false);
    if (widget.controller.waitingForPin && mounted) {
      await _showPinDialog(context, widget.controller);
    }
  }

  Future<void> _scan() async {
    if (!Platform.isAndroid) return;
    final value = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const _ScannerPage()));
    if (value == null) return;
    setState(() => _busy = true);
    await widget.controller.connectQr(value);
    if (mounted) setState(() => _busy = false);
    if (widget.controller.waitingForPin && mounted) {
      await _showPinDialog(context, widget.controller);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(
              icon: Icons.link_rounded,
              title: 'Connecter un appareil',
              subtitle: 'QR, découverte locale ou adresse IP.',
            ),
            if (Platform.isAndroid) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('Scanner le QR CastFlow'),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _address,
                    onSubmitted: (_) => _connectManual(),
                    decoration: const InputDecoration(
                      labelText: 'Adresse du PC',
                      hintText: '192.168.1.20:53317',
                      prefixIcon: Icon(Icons.lan_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filled(
                  onPressed: _busy ? null : _connectManual,
                  icon: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_forward_rounded),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  'Appareils détectés',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Actualiser',
                  onPressed: widget.controller.refreshDiscovery,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (widget.controller.devices.isEmpty)
              const _EmptyState(
                icon: Icons.wifi_find_rounded,
                text: 'Aucun appareil détecté. Vérifiez que les deux appareils sont sur le même réseau.',
              )
            else
              ...widget.controller.devices.map(
                (device) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: CastColors.panelLight,
                    child: Icon(
                      device.kind == 'desktop'
                          ? Icons.computer_rounded
                          : Icons.smartphone_rounded,
                    ),
                  ),
                  title: Text(device.name),
                  subtitle: Text('${device.host}:${device.httpPort}'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await widget.controller.connect(device);
                          if (!context.mounted) return;
                          setState(() => _busy = false);
                          if (widget.controller.waitingForPin) {
                            await _showPinDialog(context, widget.controller);
                          }
                        },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TransferPage extends StatelessWidget {
  const _TransferPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final canSend = controller.clientConnected || controller.hasInboundPeer;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.pendingTransfers.isNotEmpty)
            ...controller.pendingTransfers.map(
              (transfer) => _IncomingRequestCard(
                transfer: transfer,
                onAccept: () => controller.acceptIncoming(transfer.id),
                onReject: () => controller.rejectIncoming(transfer.id),
              ),
            ),
          if (controller.incomingOffer != null)
            _OfferCard(
              controller: controller,
              offer: controller.incomingOffer!,
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(
                    icon: Icons.upload_file_rounded,
                    title: 'Envoyer des fichiers',
                    subtitle: canSend
                        ? 'Le flux est envoyé directement sur le réseau local.'
                        : 'Connectez d’abord un autre appareil.',
                  ),
                  const SizedBox(height: 18),
                  OutlinedButton.icon(
                    onPressed: controller.pickFiles,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Choisir des fichiers'),
                  ),
                  const SizedBox(height: 12),
                  if (controller.selectedFiles.isEmpty)
                    const _EmptyState(
                      icon: Icons.folder_open_rounded,
                      text: 'Aucun fichier sélectionné',
                    )
                  else
                    ...controller.selectedFiles.map(
                      (file) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const CircleAvatar(
                          backgroundColor: CastColors.panelLight,
                          child: Icon(Icons.insert_drive_file_outlined),
                        ),
                        title: Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(formatBytes(file.size)),
                        trailing: IconButton(
                          onPressed: () => controller.removeFile(file.id),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ),
                  if (controller.totalTransferBytes > 0) ...[
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                      value: controller.totalTransferBytes == 0
                          ? 0
                          : (controller.transferredBytes /
                                    controller.totalTransferBytes)
                                .clamp(0, 1),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${formatBytes(controller.transferredBytes)} / ${formatBytes(controller.totalTransferBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          canSend &&
                              controller.selectedFiles.isNotEmpty &&
                              !controller.transferring
                          ? controller.sendSelected
                          : null,
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Envoyer maintenant'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IncomingRequestCard extends StatelessWidget {
  const _IncomingRequestCard({
    required this.transfer,
    required this.onAccept,
    required this.onReject,
  });

  final TransferSnapshot transfer;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: CastColors.cyan.withValues(alpha: .08),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Transfert entrant de ${transfer.peerName}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '${transfer.fileCount} fichier(s) · ${formatBytes(transfer.totalBytes)}',
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                OutlinedButton(
                  onPressed: onReject,
                  child: const Text('Refuser'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: onAccept,
                  child: const Text('Accepter'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({required this.controller, required this.offer});

  final AppController controller;
  final IncomingOffer offer;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: CastColors.green.withValues(alpha: .08),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fichiers proposés par le PC',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '${offer.files.length} fichier(s) · ${formatBytes(offer.totalSize)}',
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                OutlinedButton(
                  onPressed: controller.rejectOffer,
                  child: const Text('Refuser'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: controller.acceptOffer,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Télécharger'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryPage extends StatelessWidget {
  const _HistoryPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.transferHistory.isEmpty) {
      return const Center(
        child: _EmptyState(
          icon: Icons.history_toggle_off_rounded,
          text: 'Les transferts de cette session apparaîtront ici.',
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: controller.transferHistory.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final transfer = controller.transferHistory[index];
        final completed = transfer.state == TransferState.completed;
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 8,
            ),
            leading: CircleAvatar(
              backgroundColor: (completed ? CastColors.green : CastColors.blue)
                  .withValues(alpha: .14),
              child: Icon(
                transfer.direction == TransferDirection.send
                    ? Icons.north_east_rounded
                    : Icons.south_west_rounded,
                color: completed ? CastColors.green : CastColors.blue,
              ),
            ),
            title: Text(
              '${transfer.fileCount} fichier(s) · ${transfer.peerName}',
            ),
            subtitle: Text(
              '${formatBytes(transfer.transferredBytes)} / ${formatBytes(transfer.totalBytes)} · ${_stateLabel(transfer.state)}',
            ),
            trailing: completed
                ? const Icon(Icons.check_circle, color: CastColors.green)
                : SizedBox(
                    width: 34,
                    height: 34,
                    child: CircularProgressIndicator(value: transfer.progress),
                  ),
          ),
        );
      },
    );
  }

  String _stateLabel(TransferState state) => switch (state) {
    TransferState.pending => 'en attente',
    TransferState.transferring => 'en cours',
    TransferState.completed => 'terminé',
    TransferState.rejected => 'refusé',
    TransferState.cancelled => 'annulé',
    TransferState.failed => 'échoué',
  };
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool _found = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_found) return;
              final value = capture.barcodes.firstOrNull?.rawValue;
              if (value == null) return;
              _found = true;
              Navigator.of(context).pop(value);
            },
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                      const Expanded(
                        child: Text(
                          'Scannez le QR affiché par CastFlow',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: CastColors.cyan, width: 3),
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: CastColors.cyan.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: CastColors.cyan),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 3),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38, color: CastColors.muted),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

Future<void> _showPinDialog(
  BuildContext context,
  AppController controller,
) async {
  final input = TextEditingController();
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('PIN requis'),
      content: TextField(
        controller: input,
        autofocus: true,
        maxLength: 6,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(hintText: '000000'),
        onSubmitted: (value) async {
          if (value.length != 6) return;
          if (await controller.submitPin(value) && context.mounted) {
            Navigator.of(context).pop();
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () {
            controller.disconnect();
            Navigator.of(context).pop();
          },
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () async {
            if (input.text.length != 6) return;
            if (await controller.submitPin(input.text) && context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: const Text('Valider'),
        ),
      ],
    ),
  );
  input.dispose();
}
