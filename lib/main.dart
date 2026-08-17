// =============================================================================
// AuraWave Desktop & Web — single-file interactive Flutter prototype
// -----------------------------------------------------------------------------
// A Wave-style invoicing app prototype with:
//   - Onboarding wizard + 6-digit PIN vault (with "forgot PIN" recovery demo)
//   - Dashboard / Invoices / Clients / Products / Recovery Bin / Cloud Settings
//   - Dynamic invoice creator with live tax/total math
//   - Printable invoice preview with a simulated UPI QR code
//   - "Gemini" voice pilot + vision intake simulations feeding a human-in-the
//     loop editable draft, plus a heavy-dataset streaming-ingestion demo
//   - 30-day soft-delete Recovery Bin
//   - Dual Google Drive sync toggles + export/import mocks
//
// Everything here is a *simulation* — there is no real network, Firebase,
// Gemini, or Drive call. Buttons are fully wired to local state so every
// screen is genuinely interactive and reflects the mock seed data.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
// ignore: unused_import
import 'package:http/http.dart' as http;

void main() {
  runApp(const AuraWaveRoot());
}

// =============================================================================
// SECTION: Shared formatting helpers
// =============================================================================

final NumberFormat _currencyFmt = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '\u{20B9} ',
  decimalDigits: 2,
);

String formatCurrency(double v) => _currencyFmt.format(v);

final DateFormat _dateFmt = DateFormat('dd MMM yyyy');
String formatDate(DateTime d) => _dateFmt.format(d);

final Random _rand = Random();

String _newId(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_rand.nextInt(9999)}';

const List<double> kGstSlabs = [0, 5, 12, 18, 28];
const List<String> kLanguages = [
  'English',
  'Hindi',
  'Gujarati',
  'Marathi',
  'Tamil',
  'Bengali',
  'Spanish',
  'French',
];

// =============================================================================
// SECTION: Models
// =============================================================================

enum InvoiceStatus { draft, sent, paid }

enum RecordType { client, product, invoice }

class LineItem {
  String id;
  String name;
  double qty;
  double unitPrice;
  double taxPercent;

  LineItem({
    required this.id,
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.taxPercent,
  });

  double get lineSubtotal => qty * unitPrice;
  double get taxAmount => lineSubtotal * taxPercent / 100.0;
  double get lineTotal => lineSubtotal + taxAmount;

  LineItem copy() => LineItem(
        id: id,
        name: name,
        qty: qty,
        unitPrice: unitPrice,
        taxPercent: taxPercent,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'qty': qty,
        'unitPrice': unitPrice,
        'taxPercent': taxPercent,
      };
}

class Client {
  String id;
  String name;
  String email;
  String phone;
  String company;
  String address;
  DateTime createdAt;

  Client({
    required this.id,
    required this.name,
    required this.email,
    required this.phone,
    required this.company,
    required this.address,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'company': company,
        'address': address,
      };
}

class Product {
  String id;
  String name;
  double defaultPrice;
  double defaultTaxPercent;
  String unit;

  Product({
    required this.id,
    required this.name,
    required this.defaultPrice,
    required this.defaultTaxPercent,
    required this.unit,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'defaultPrice': defaultPrice,
        'defaultTaxPercent': defaultTaxPercent,
        'unit': unit,
      };
}

class Invoice {
  String id;
  String invoiceNumber;
  String clientId;
  DateTime issueDate;
  DateTime dueDate;
  List<LineItem> items;
  InvoiceStatus status;
  String notes;
  DateTime? paidDate;
  bool aiGenerated;

  Invoice({
    required this.id,
    required this.invoiceNumber,
    required this.clientId,
    required this.issueDate,
    required this.dueDate,
    required this.items,
    required this.status,
    this.notes = '',
    this.paidDate,
    this.aiGenerated = false,
  });

  double get subtotal => items.fold(0.0, (s, i) => s + i.lineSubtotal);
  double get taxTotal => items.fold(0.0, (s, i) => s + i.taxAmount);
  double get grandTotal => subtotal + taxTotal;

  /// Effective status for display purposes — a "sent" invoice whose due
  /// date has passed is treated as overdue without mutating stored data.
  bool get isOverdue =>
      status == InvoiceStatus.sent && dueDate.isBefore(DateTime.now());

  String get displayStatusLabel {
    if (isOverdue) return 'Overdue';
    switch (status) {
      case InvoiceStatus.draft:
        return 'Draft';
      case InvoiceStatus.sent:
        return 'Sent';
      case InvoiceStatus.paid:
        return 'Paid';
    }
  }

  Map<String, double> get taxBreakdown {
    final Map<String, double> map = {};
    for (final item in items) {
      final key = '${item.taxPercent.toStringAsFixed(item.taxPercent % 1 == 0 ? 0 : 1)}%';
      map[key] = (map[key] ?? 0) + item.taxAmount;
    }
    return map;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'invoiceNumber': invoiceNumber,
        'clientId': clientId,
        'issueDate': issueDate.toIso8601String(),
        'dueDate': dueDate.toIso8601String(),
        'status': status.name,
        'notes': notes,
        'items': items.map((i) => i.toJson()).toList(),
        'grandTotal': grandTotal,
      };
}

class DeletedRecord {
  final String id;
  final RecordType type;
  final dynamic data;
  final String label;
  final DateTime deletedAt;

  DeletedRecord({
    required this.id,
    required this.type,
    required this.data,
    required this.label,
    required this.deletedAt,
  });

  DateTime get purgeDate => deletedAt.add(const Duration(days: 30));
  int get daysRemaining =>
      purgeDate.difference(DateTime.now()).inHours ~/ 24 + 1;
}

class SubClientProfile {
  final String id;
  final String name;
  final String email;
  final String storageId;
  SubClientProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.storageId,
  });
}

// =============================================================================
// SECTION: AppState — single source of truth for the whole prototype
// =============================================================================

class AppState extends ChangeNotifier {
  // ---- Onboarding / security -------------------------------------------------
  bool onboardingComplete = false;
  bool locked = true;
  String? _pin;

  String country = '';
  String state = '';
  String city = '';
  String language = 'English';
  String primaryGmail = '';
  String backupGmail = '';
  bool telemetryEnabled = false;

  // ---- Data --------------------------------------------------------------
  final List<Client> clients = [];
  final List<Product> products = [];
  final List<Invoice> invoices = [];
  final List<DeletedRecord> recycleBin = [];
  final List<SubClientProfile> subClients = [];

  int _invoiceCounter = 1024;

  // ---- Cloud sync ----------------------------------------------------------
  bool primaryDriveSync = true;
  bool backupDriveSync = false;
  DateTime? lastSyncTime;

  // ---- AI draft pipeline -----------------------------------------------------
  Invoice? draftFromAi;
  String? draftSourceLabel;

  // ---------------------------------------------------------------------------
  void seedData() {
    final now = DateTime.now();

    clients.addAll([
      Client(
        id: _newId('cl'),
        name: 'Rajesh Kumar',
        email: 'rajesh@brightbuild.in',
        phone: '+91 98200 11223',
        company: 'BrightBuild Interiors',
        address: 'A-12, Sector 18, Noida, UP',
        createdAt: now.subtract(const Duration(days: 210)),
      ),
      Client(
        id: _newId('cl'),
        name: 'Meera Nair',
        email: 'meera@lotusretail.com',
        phone: '+91 90080 44556',
        company: 'Lotus Retail Pvt Ltd',
        address: '221 MG Road, Bengaluru, KA',
        createdAt: now.subtract(const Duration(days: 160)),
      ),
      Client(
        id: _newId('cl'),
        name: 'Arjun Singh',
        email: 'arjun@peakventures.co',
        phone: '+91 99110 22334',
        company: 'Peak Ventures',
        address: '5th Floor, Cyber Hub, Gurugram, HR',
        createdAt: now.subtract(const Duration(days: 95)),
      ),
      Client(
        id: _newId('cl'),
        name: 'Fatima Sheikh',
        email: 'fatima@oraclestudio.design',
        phone: '+91 97025 66778',
        company: 'Oracle Design Studio',
        address: '14 Marine Drive, Mumbai, MH',
        createdAt: now.subtract(const Duration(days: 40)),
      ),
    ]);

    products.addAll([
      Product(id: _newId('pr'), name: 'Web Design (per page)', defaultPrice: 5000, defaultTaxPercent: 18, unit: 'page'),
      Product(id: _newId('pr'), name: 'Logo & Brand Identity', defaultPrice: 15000, defaultTaxPercent: 18, unit: 'project'),
      Product(id: _newId('pr'), name: 'Consulting (hourly)', defaultPrice: 2500, defaultTaxPercent: 18, unit: 'hour'),
      Product(id: _newId('pr'), name: 'Interior Design Package', defaultPrice: 45000, defaultTaxPercent: 12, unit: 'project'),
      Product(id: _newId('pr'), name: 'Cloud Hosting (monthly)', defaultPrice: 1800, defaultTaxPercent: 18, unit: 'month'),
      Product(id: _newId('pr'), name: 'Product Photography', defaultPrice: 3500, defaultTaxPercent: 5, unit: 'shoot'),
    ]);

    Invoice mkInvoice({
      required Client client,
      required List<LineItem> items,
      required InvoiceStatus status,
      required int issuedDaysAgo,
      int dueInDays = 14,
      DateTime? paidDate,
    }) {
      final issue = now.subtract(Duration(days: issuedDaysAgo));
      return Invoice(
        id: _newId('inv'),
        invoiceNumber: 'INV-${_invoiceCounter++}',
        clientId: client.id,
        issueDate: issue,
        dueDate: issue.add(Duration(days: dueInDays)),
        items: items,
        status: status,
        paidDate: paidDate,
      );
    }

    invoices.addAll([
      mkInvoice(
        client: clients[0],
        items: [
          LineItem(id: _newId('li'), name: 'Interior Design Package', qty: 1, unitPrice: 45000, taxPercent: 12),
        ],
        status: InvoiceStatus.paid,
        issuedDaysAgo: 70,
        paidDate: now.subtract(const Duration(days: 55)),
      ),
      mkInvoice(
        client: clients[1],
        items: [
          LineItem(id: _newId('li'), name: 'Web Design (per page)', qty: 6, unitPrice: 5000, taxPercent: 18),
          LineItem(id: _newId('li'), name: 'Cloud Hosting (monthly)', qty: 3, unitPrice: 1800, taxPercent: 18),
        ],
        status: InvoiceStatus.paid,
        issuedDaysAgo: 40,
        paidDate: now.subtract(const Duration(days: 28)),
      ),
      mkInvoice(
        client: clients[2],
        items: [
          LineItem(id: _newId('li'), name: 'Consulting (hourly)', qty: 12, unitPrice: 2500, taxPercent: 18),
        ],
        status: InvoiceStatus.sent,
        issuedDaysAgo: 45,
        dueInDays: 15, // now overdue
      ),
      mkInvoice(
        client: clients[3],
        items: [
          LineItem(id: _newId('li'), name: 'Logo & Brand Identity', qty: 1, unitPrice: 15000, taxPercent: 18),
          LineItem(id: _newId('li'), name: 'Product Photography', qty: 2, unitPrice: 3500, taxPercent: 5),
        ],
        status: InvoiceStatus.sent,
        issuedDaysAgo: 5,
        dueInDays: 20, // due soon
      ),
      mkInvoice(
        client: clients[0],
        items: [
          LineItem(id: _newId('li'), name: 'Consulting (hourly)', qty: 4, unitPrice: 2500, taxPercent: 18),
        ],
        status: InvoiceStatus.draft,
        issuedDaysAgo: 1,
        dueInDays: 14,
      ),
      mkInvoice(
        client: clients[1],
        items: [
          LineItem(id: _newId('li'), name: 'Web Design (per page)', qty: 3, unitPrice: 5000, taxPercent: 18),
        ],
        status: InvoiceStatus.sent,
        issuedDaysAgo: 60,
        dueInDays: 10, // overdue
      ),
      mkInvoice(
        client: clients[2],
        items: [
          LineItem(id: _newId('li'), name: 'Cloud Hosting (monthly)', qty: 1, unitPrice: 1800, taxPercent: 18),
        ],
        status: InvoiceStatus.paid,
        issuedDaysAgo: 15,
        paidDate: now.subtract(const Duration(days: 10)),
      ),
      mkInvoice(
        client: clients[3],
        items: [
          LineItem(id: _newId('li'), name: 'Interior Design Package', qty: 1, unitPrice: 45000, taxPercent: 12),
          LineItem(id: _newId('li'), name: 'Product Photography', qty: 1, unitPrice: 3500, taxPercent: 5),
        ],
        status: InvoiceStatus.sent,
        issuedDaysAgo: 3,
        dueInDays: 25,
      ),
    ]);

    subClients.add(
      SubClientProfile(
        id: _newId('sub'),
        name: 'AuraWave — Freelance Ops',
        email: 'ops@aurawave.demo',
        storageId: 'fs-instance-${_rand.nextInt(90000) + 10000}',
      ),
    );

    lastSyncTime = now.subtract(const Duration(hours: 3));
  }

  // ---- Onboarding ------------------------------------------------------------
  void completeOnboarding({
    required String country,
    required String state,
    required String city,
    required String language,
    required String primaryGmail,
    required String backupGmail,
    required String pin,
  }) {
    this.country = country;
    this.state = state;
    this.city = city;
    this.language = language;
    this.primaryGmail = primaryGmail;
    this.backupGmail = backupGmail;
    _pin = pin;
    onboardingComplete = true;
    locked = true;
    notifyListeners();
  }

  bool verifyPin(String candidate) => candidate == _pin;

  void setupPin(String pin) {
    _pin = pin;
    notifyListeners();
  }

  void unlock() {
    locked = false;
    notifyListeners();
  }

  void lock() {
    locked = true;
    notifyListeners();
  }

  /// Simulates dispatching a recovery code to both registered Gmail IDs.
  String requestPinRecoveryCode() {
    final code = (100000 + _rand.nextInt(899999)).toString();
    return code;
  }

  // ---- Clients -----------------------------------------------------------
  void addClient(Client c) {
    clients.add(c);
    notifyListeners();
  }

  void updateClient(Client updated) {
    final idx = clients.indexWhere((c) => c.id == updated.id);
    if (idx != -1) clients[idx] = updated;
    notifyListeners();
  }

  void softDeleteClient(String id) {
    final idx = clients.indexWhere((c) => c.id == id);
    if (idx == -1) return;
    final c = clients.removeAt(idx);
    recycleBin.add(DeletedRecord(
      id: _newId('bin'),
      type: RecordType.client,
      data: c,
      label: c.name,
      deletedAt: DateTime.now(),
    ));
    notifyListeners();
  }

  // ---- Products ----------------------------------------------------------
  void addProduct(Product p) {
    products.add(p);
    notifyListeners();
  }

  void updateProduct(Product updated) {
    final idx = products.indexWhere((p) => p.id == updated.id);
    if (idx != -1) products[idx] = updated;
    notifyListeners();
  }

  void softDeleteProduct(String id) {
    final idx = products.indexWhere((p) => p.id == id);
    if (idx == -1) return;
    final p = products.removeAt(idx);
    recycleBin.add(DeletedRecord(
      id: _newId('bin'),
      type: RecordType.product,
      data: p,
      label: p.name,
      deletedAt: DateTime.now(),
    ));
    notifyListeners();
  }

  // ---- Invoices ------------------------------------------------------------
  String generateInvoiceNumber() => 'INV-${_invoiceCounter++}';

  void addInvoice(Invoice inv) {
    invoices.add(inv);
    notifyListeners();
  }

  void updateInvoice(Invoice updated) {
    final idx = invoices.indexWhere((i) => i.id == updated.id);
    if (idx != -1) invoices[idx] = updated;
    notifyListeners();
  }

  void markInvoicePaid(String id) {
    final idx = invoices.indexWhere((i) => i.id == id);
    if (idx == -1) return;
    invoices[idx].status = InvoiceStatus.paid;
    invoices[idx].paidDate = DateTime.now();
    notifyListeners();
  }

  void sendInvoice(String id) {
    final idx = invoices.indexWhere((i) => i.id == id);
    if (idx == -1) return;
    invoices[idx].status = InvoiceStatus.sent;
    notifyListeners();
  }

  void softDeleteInvoice(String id) {
    final idx = invoices.indexWhere((i) => i.id == id);
    if (idx == -1) return;
    final inv = invoices.removeAt(idx);
    recycleBin.add(DeletedRecord(
      id: _newId('bin'),
      type: RecordType.invoice,
      data: inv,
      label: inv.invoiceNumber,
      deletedAt: DateTime.now(),
    ));
    notifyListeners();
  }

  // ---- Recovery bin --------------------------------------------------------
  void restoreRecord(String binId) {
    final idx = recycleBin.indexWhere((r) => r.id == binId);
    if (idx == -1) return;
    final rec = recycleBin.removeAt(idx);
    switch (rec.type) {
      case RecordType.client:
        clients.add(rec.data as Client);
        break;
      case RecordType.product:
        products.add(rec.data as Product);
        break;
      case RecordType.invoice:
        invoices.add(rec.data as Invoice);
        break;
    }
    notifyListeners();
  }

  void purgeRecord(String binId) {
    recycleBin.removeWhere((r) => r.id == binId);
    notifyListeners();
  }

  // ---- Master-client management ----------------------------------------------
  void addSubClient(String name, String email) {
    subClients.add(SubClientProfile(
      id: _newId('sub'),
      name: name,
      email: email,
      storageId: 'fs-instance-${_rand.nextInt(90000) + 10000}',
    ));
    notifyListeners();
  }

  void removeSubClient(String id) {
    subClients.removeWhere((s) => s.id == id);
    notifyListeners();
  }

  // ---- Cloud sync ------------------------------------------------------------
  Future<void> syncNow() async {
    await Future.delayed(const Duration(milliseconds: 900));
    lastSyncTime = DateTime.now();
    // Best-effort, purely illustrative handshake — never blocks the UI and
    // failures (e.g. no network in this sandbox) are swallowed silently.
    unawaited(_attemptHandshake());
    notifyListeners();
  }

  Future<void> _attemptHandshake() async {
    try {
      await http
          .get(Uri.parse('https://example.invalid/aurawave-handshake'))
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {
      // Expected in this offline prototype — sync state above is what
      // actually drives the UI, this is purely a simulated background call.
    }
  }

  String exportJson() {
    final payload = {
      'exportedAt': DateTime.now().toIso8601String(),
      'clients': clients.map((c) => c.toJson()).toList(),
      'products': products.map((p) => p.toJson()).toList(),
      'invoices': invoices.map((i) => i.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  // ---- AI draft pipeline -----------------------------------------------------
  Invoice _buildDraftInvoice(List<LineItem> items, String clientName) {
    Client? existing;
    for (final c in clients) {
      if (c.name.toLowerCase() == clientName.trim().toLowerCase()) {
        existing = c;
        break;
      }
    }
    final client = existing ??
        Client(
          id: _newId('cl'),
          name: clientName.trim().isEmpty ? 'New Client' : clientName.trim(),
          email: '',
          phone: '',
          company: '',
          address: '',
          createdAt: DateTime.now(),
        );
    if (existing == null) {
      clients.add(client);
    }
    final now = DateTime.now();
    return Invoice(
      id: _newId('inv'),
      invoiceNumber: generateInvoiceNumber(),
      clientId: client.id,
      issueDate: now,
      dueDate: now.add(const Duration(days: 14)),
      items: items,
      status: InvoiceStatus.draft,
      aiGenerated: true,
    );
  }

  /// Parses a natural-language-ish voice command into an editable draft.
  /// Falls back to a generic single-line draft if parsing fails, so the
  /// pilot never dead-ends regardless of what the user types.
  Invoice simulateVoiceCommand(String command) {
    final regex = RegExp(
      r'invoice for\s+([A-Za-z .]+?)\s*:\s*(\d+(?:\.\d+)?)\s+([A-Za-z0-9 /\-]+?)\s+at\s+(\d+(?:\.\d+)?)\s*each(?:\s+with\s+(\d+(?:\.\d+)?)\s*%?\s*GST)?',
      caseSensitive: false,
    );
    final match = regex.firstMatch(command);
    late Invoice draft;
    if (match != null) {
      final clientName = match.group(1) ?? 'New Client';
      final qty = double.tryParse(match.group(2) ?? '1') ?? 1;
      final itemName = (match.group(3) ?? 'Service').trim();
      final price = double.tryParse(match.group(4) ?? '0') ?? 0;
      final tax = double.tryParse(match.group(5) ?? '18') ?? 18;
      final item = LineItem(
        id: _newId('li'),
        name: itemName[0].toUpperCase() + itemName.substring(1),
        qty: qty,
        unitPrice: price,
        taxPercent: tax,
      );
      draft = _buildDraftInvoice([item], clientName);
    } else {
      // Fallback: still produce something useful and editable.
      final item = LineItem(
        id: _newId('li'),
        name: command.trim().isEmpty ? 'Voice-dictated item' : command.trim(),
        qty: 1,
        unitPrice: 0,
        taxPercent: 18,
      );
      draft = _buildDraftInvoice([item], 'New Client');
    }
    draftFromAi = draft;
    draftSourceLabel = 'Voice Pilot';
    notifyListeners();
    return draft;
  }

  /// Simulates Gemini Vision OCR extraction with PII auto-redaction.
  Invoice simulateVisionExtraction(String fileName) {
    final sampleItems = [
      LineItem(id: _newId('li'), name: 'Consulting (hourly)', qty: 3, unitPrice: 2500, taxPercent: 18),
      LineItem(id: _newId('li'), name: 'Cloud Hosting (monthly)', qty: 1, unitPrice: 1800, taxPercent: 18),
    ];
    final draft = _buildDraftInvoice(sampleItems, 'Scanned Vendor');
    draft.notes =
        'Extracted from "$fileName" via Gemini 1.5 Flash Vision (simulated).\n'
        'PII auto-redacted: Aadhaar [Aadhaar Redacted], UPI RRN [RRN Omitted], Phone [Redacted].';
    draftFromAi = draft;
    draftSourceLabel = 'Vision Intake';
    notifyListeners();
    return draft;
  }

  void clearAiDraft() {
    draftFromAi = null;
    draftSourceLabel = null;
  }

  // ---- Dashboard metrics -----------------------------------------------------
  double get totalOverdue =>
      invoices.where((i) => i.isOverdue).fold(0.0, (s, i) => s + i.grandTotal);

  double get totalDueSoon => invoices
      .where((i) =>
          i.status == InvoiceStatus.sent &&
          !i.isOverdue &&
          i.dueDate.isBefore(DateTime.now().add(const Duration(days: 30))))
      .fold(0.0, (s, i) => s + i.grandTotal);

  double get totalPaid => invoices
      .where((i) => i.status == InvoiceStatus.paid)
      .fold(0.0, (s, i) => s + i.grandTotal);

  List<double> get monthlyPaidTotals {
    final now = DateTime.now();
    final result = <double>[];
    for (int i = 5; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i, 1);
      final sum = invoices
          .where((inv) =>
              inv.status == InvoiceStatus.paid &&
              (inv.paidDate ?? inv.issueDate).year == month.year &&
              (inv.paidDate ?? inv.issueDate).month == month.month)
          .fold(0.0, (s, inv) => s + inv.grandTotal);
      result.add(sum);
    }
    return result;
  }

  List<String> get monthlyLabels {
    final now = DateTime.now();
    final fmt = DateFormat('MMM');
    return [
      for (int i = 5; i >= 0; i--) fmt.format(DateTime(now.year, now.month - i, 1)),
    ];
  }

  Client? clientById(String id) {
    for (final c in clients) {
      if (c.id == id) return c;
    }
    return null;
  }
}

// =============================================================================
// SECTION: App root + inherited scope
// =============================================================================

class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState super.notifier,
    required super.child,
  });

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'No AppStateScope found in context');
    return scope!.notifier!;
  }
}

class AuraWaveRoot extends StatefulWidget {
  const AuraWaveRoot({super.key});

  @override
  State<AuraWaveRoot> createState() => _AuraWaveRootState();
}

class _AuraWaveRootState extends State<AuraWaveRoot> {
  late final AppState appState;

  @override
  void initState() {
    super.initState();
    appState = AppState()..seedData();
  }

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: appState,
      child: MaterialApp(
        title: 'AuraWave Desktop & Web',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF3454D1),
          scaffoldBackgroundColor: const Color(0xFFF5F6FA),
        ),
        home: const AppGate(),
      ),
    );
  }
}

class AppGate extends StatelessWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    if (!app.onboardingComplete) return const OnboardingWizard();
    if (app.locked) return const PinGateScreen();
    return const HomeShell();
  }
}

// =============================================================================
// SECTION: Shared small widgets
// =============================================================================

class StatusBadge extends StatelessWidget {
  final String status;
  const StatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case 'Paid':
        color = Colors.green;
        break;
      case 'Overdue':
        color = Colors.red;
        break;
      case 'Sent':
        color = Colors.blue;
        break;
      default:
        color = Colors.grey;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        status,
        style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}

class KpiCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  const KpiCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 230,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

Future<Map<String, String>?> showFormDialog(
  BuildContext context, {
  required String title,
  required List<String> fields,
  Map<String, String>? initial,
}) {
  final controllers = {
    for (final f in fields) f: TextEditingController(text: initial?[f] ?? ''),
  };
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: fields
                .map((f) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: TextField(
                        controller: controllers[f],
                        decoration: InputDecoration(labelText: f, border: const OutlineInputBorder()),
                      ),
                    ))
                .toList(),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final result = {for (final f in fields) f: controllers[f]!.text.trim()};
            Navigator.pop(ctx, result);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

// =============================================================================
// SECTION: Onboarding wizard
// =============================================================================

class OnboardingWizard extends StatefulWidget {
  const OnboardingWizard({super.key});

  @override
  State<OnboardingWizard> createState() => _OnboardingWizardState();
}

class _OnboardingWizardState extends State<OnboardingWizard> {
  int _step = 0;
  bool _provisioning = false;

  final _countryCtrl = TextEditingController(text: 'India');
  final _stateCtrl = TextEditingController(text: 'Gujarat');
  final _cityCtrl = TextEditingController(text: 'Ahmedabad');
  String _language = 'English';
  final _primaryGmailCtrl = TextEditingController();
  final _backupGmailCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _pinConfirmCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _countryCtrl.dispose();
    _stateCtrl.dispose();
    _cityCtrl.dispose();
    _primaryGmailCtrl.dispose();
    _backupGmailCtrl.dispose();
    _pinCtrl.dispose();
    _pinConfirmCtrl.dispose();
    super.dispose();
  }

  bool _validateStep(int step) {
    setState(() => _error = null);
    if (step == 0) {
      if (_countryCtrl.text.trim().isEmpty || _stateCtrl.text.trim().isEmpty || _cityCtrl.text.trim().isEmpty) {
        setState(() => _error = 'Please fill in country, state and city.');
        return false;
      }
    } else if (step == 2) {
      if (!_primaryGmailCtrl.text.contains('@')) {
        setState(() => _error = 'Enter a valid primary Gmail ID.');
        return false;
      }
      if (!_backupGmailCtrl.text.contains('@')) {
        setState(() => _error = 'Enter a valid backup Gmail ID.');
        return false;
      }
      if (_primaryGmailCtrl.text.trim().toLowerCase() == _backupGmailCtrl.text.trim().toLowerCase()) {
        setState(() => _error = 'Backup Gmail should differ from the primary one.');
        return false;
      }
    } else if (step == 3) {
      if (_pinCtrl.text.length != 6 || int.tryParse(_pinCtrl.text) == null) {
        setState(() => _error = 'PIN must be exactly 6 digits.');
        return false;
      }
      if (_pinCtrl.text != _pinConfirmCtrl.text) {
        setState(() => _error = 'PIN confirmation does not match.');
        return false;
      }
    }
    return true;
  }

  Future<void> _finish() async {
    if (!_validateStep(3)) return;
    setState(() => _provisioning = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    final app = AppStateScope.of(context);
    app.completeOnboarding(
      country: _countryCtrl.text.trim(),
      state: _stateCtrl.text.trim(),
      city: _cityCtrl.text.trim(),
      language: _language,
      primaryGmail: _primaryGmailCtrl.text.trim(),
      backupGmail: _backupGmailCtrl.text.trim(),
      pin: _pinCtrl.text,
    );
    setState(() => _provisioning = false);
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      Step(
        title: const Text('Location'),
        isActive: _step >= 0,
        state: _step > 0 ? StepState.complete : StepState.indexed,
        content: Column(
          children: [
            TextField(controller: _countryCtrl, decoration: const InputDecoration(labelText: 'Country', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: _stateCtrl, decoration: const InputDecoration(labelText: 'State', border: OutlineInputBorder())),
            const SizedBox(height: 12),
            TextField(controller: _cityCtrl, decoration: const InputDecoration(labelText: 'City', border: OutlineInputBorder())),
          ],
        ),
      ),
      Step(
        title: const Text('Interface Language'),
        isActive: _step >= 1,
        state: _step > 1 ? StepState.complete : StepState.indexed,
        content: DropdownButtonFormField<String>(
          initialValue: _language,
          decoration: const InputDecoration(labelText: 'Language', border: OutlineInputBorder()),
          items: kLanguages.map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(),
          onChanged: (v) => setState(() => _language = v ?? 'English'),
        ),
      ),
      Step(
        title: const Text('Dual Gmail Setup'),
        isActive: _step >= 2,
        state: _step > 2 ? StepState.complete : StepState.indexed,
        content: Column(
          children: [
            TextField(
              controller: _primaryGmailCtrl,
              decoration: const InputDecoration(labelText: 'Primary Gmail ID', hintText: 'you@gmail.com', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _backupGmailCtrl,
              decoration: const InputDecoration(labelText: 'Backup Gmail ID', hintText: 'backup@gmail.com', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      Step(
        title: const Text('Create 6-Digit PIN'),
        isActive: _step >= 3,
        state: _step > 3 ? StepState.complete : StepState.indexed,
        content: Column(
          children: [
            TextField(
              controller: _pinCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'New 6-digit PIN', border: OutlineInputBorder()),
            ),
            TextField(
              controller: _pinConfirmCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Confirm PIN', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      Step(
        title: const Text('Review & Provision'),
        isActive: _step >= 4,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Location: ${_cityCtrl.text}, ${_stateCtrl.text}, ${_countryCtrl.text}'),
            Text('Language: $_language'),
            Text('Primary Gmail: ${_primaryGmailCtrl.text}'),
            Text('Backup Gmail: ${_backupGmailCtrl.text}'),
            const SizedBox(height: 16),
            const Text(
              'Finishing setup will simulate provisioning a multi-tenant '
              'Firebase instance for remote browser access.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      ),
    ];

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(colors: [Color(0xFF3454D1), Color(0xFF6C8DFA)]),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.auto_awesome, color: Colors.white, size: 28),
                      SizedBox(width: 12),
                      Text('Welcome to AuraWave',
                          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: Colors.red.shade50,
                    padding: const EdgeInsets.all(10),
                    child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                  ),
                if (_provisioning)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        LinearProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Provisioning secure multi-tenant instance…'),
                      ],
                    ),
                  )
                else
                  Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: Theme.of(context).colorScheme.copyWith(primary: const Color(0xFF3454D1)),
                    ),
                    child: Stepper(
                      currentStep: _step,
                      steps: steps,
                      controlsBuilder: (context, details) {
                        final isLast = _step == steps.length - 1;
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              if (_step > 0)
                                OutlinedButton(
                                  onPressed: () => setState(() => _step -= 1),
                                  child: const Text('Back'),
                                ),
                              const SizedBox(width: 12),
                              FilledButton(
                                onPressed: () {
                                  if (isLast) {
                                    _finish();
                                  } else if (_validateStep(_step)) {
                                    setState(() => _step += 1);
                                  }
                                },
                                child: Text(isLast ? 'Complete Setup' : 'Continue'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SECTION: PIN gate
// =============================================================================

class PinGateScreen extends StatefulWidget {
  const PinGateScreen({super.key});

  @override
  State<PinGateScreen> createState() => _PinGateScreenState();
}

class _PinGateScreenState extends State<PinGateScreen> {
  String _entered = '';
  String? _error;

  void _onDigit(String d) {
    if (_entered.length >= 6) return;
    setState(() {
      _entered += d;
      _error = null;
    });
    if (_entered.length == 6) {
      final app = AppStateScope.of(context);
      if (app.verifyPin(_entered)) {
        app.unlock();
      } else {
        setState(() => _error = 'Incorrect PIN. Please try again.');
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted) setState(() => _entered = '');
        });
      }
    }
  }

  void _backspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _forgotPin() async {
    final app = AppStateScope.of(context);
    final code = app.requestPinRecoveryCode();
    final codeCtrl = TextEditingController();
    final newPinCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? dialogError;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Recover PIN'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A recovery code was sent to both:\n'
                  '• ${app.primaryGmail.isEmpty ? "(primary Gmail)" : app.primaryGmail}\n'
                  '• ${app.backupGmail.isEmpty ? "(backup Gmail)" : app.backupGmail}',
                ),
                const SizedBox(height: 8),
                Text('Demo recovery code: $code', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Enter recovery code', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: newPinCtrl,
                  obscureText: true,
                  maxLength: 6,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'New 6-digit PIN', border: OutlineInputBorder()),
                ),
                TextField(
                  controller: confirmCtrl,
                  obscureText: true,
                  maxLength: 6,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Confirm new PIN', border: OutlineInputBorder()),
                ),
                if (dialogError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(dialogError!, style: const TextStyle(color: Colors.red)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (codeCtrl.text.trim() != code) {
                  setDialogState(() => dialogError = 'Recovery code does not match.');
                  return;
                }
                if (newPinCtrl.text.length != 6 || newPinCtrl.text != confirmCtrl.text) {
                  setDialogState(() => dialogError = 'PIN must be 6 digits and match confirmation.');
                  return;
                }
                app.setupPin(newPinCtrl.text);
                app.unlock();
                Navigator.pop(ctx);
              },
              child: const Text('Reset PIN & Unlock'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _digitKey(String d) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 1,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _onDigit(d),
          child: Center(child: Text(d, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600))),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF3454D1),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, color: Colors.white, size: 44),
              const SizedBox(height: 12),
              const Text('Enter your 6-digit PIN', style: TextStyle(color: Colors.white, fontSize: 18)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(6, (i) {
                  final filled = i < _entered.length;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? Colors.white : Colors.transparent,
                      border: Border.all(color: Colors.white),
                    ),
                  );
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
              ],
              const SizedBox(height: 28),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9']) _digitKey(d),
                  const SizedBox(width: 72, height: 72),
                  _digitKey('0'),
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: IconButton(
                      onPressed: _backspace,
                      icon: const Icon(Icons.backspace_outlined, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              TextButton(
                onPressed: _forgotPin,
                child: const Text('Forgot PIN?', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// SECTION: Home shell (NavigationRail + routed content)
// =============================================================================

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _titles = ['Dashboard', 'Invoices', 'Clients', 'Products', 'Recovery Bin', 'Cloud & Settings'];

  void _openInvoiceCreator({Invoice? existing, Invoice? aiDraft}) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => InvoiceCreatorScreen(existing: existing, aiDraft: aiDraft)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);

    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: FloatingActionButton(
                    heroTag: 'new-invoice-fab',
                    tooltip: 'New Invoice',
                    onPressed: () => _openInvoiceCreator(),
                    child: const Icon(Icons.add),
                  ),
                ),
                destinations: const [
                  NavigationRailDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: Text('Dashboard')),
                  NavigationRailDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: Text('Invoices')),
                  NavigationRailDestination(icon: Icon(Icons.people_outline), selectedIcon: Icon(Icons.people), label: Text('Clients')),
                  NavigationRailDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: Text('Products')),
                  NavigationRailDestination(icon: Icon(Icons.restore_from_trash_outlined), selectedIcon: Icon(Icons.restore_from_trash), label: Text('Bin')),
                  NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('Settings')),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                      ),
                      child: Row(
                        children: [
                          Text(_titles[_index], style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                          const Spacer(),
                          Icon(Icons.cloud_done_outlined,
                              size: 18, color: app.primaryDriveSync ? Colors.green : Colors.grey),
                          const SizedBox(width: 6),
                          Text(
                            app.lastSyncTime == null
                                ? 'Not synced yet'
                                : 'Synced ${DateFormat('hh:mm a').format(app.lastSyncTime!)}',
                            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                          ),
                          const SizedBox(width: 20),
                          OutlinedButton.icon(
                            onPressed: () => app.lock(),
                            icon: const Icon(Icons.lock_outline, size: 16),
                            label: const Text('Lock'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: _index,
                        children: [
                          const DashboardView(),
                          InvoicesView(onOpenCreator: _openInvoiceCreator),
                          const ClientsView(),
                          const ProductsView(),
                          const RecoveryBinView(),
                          const SettingsView(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            right: 28,
            bottom: 88,
            child: FloatingActionButton(
              heroTag: 'vision-fab',
              tooltip: 'Gemini Vision Intake',
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF3454D1),
              onPressed: () => showVisionIntakeDialog(context, onDraftReady: (draft) => _openInvoiceCreator(aiDraft: draft)),
              child: const Icon(Icons.document_scanner_outlined),
            ),
          ),
          Positioned(
            right: 28,
            bottom: 20,
            child: FloatingActionButton.extended(
              heroTag: 'voice-fab',
              backgroundColor: const Color(0xFF3454D1),
              onPressed: () => showVoicePilotSheet(context, onDraftReady: (draft) => _openInvoiceCreator(aiDraft: draft)),
              icon: const Icon(Icons.mic),
              label: const Text('Voice Pilot'),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION: Dashboard
// =============================================================================

class DashboardView extends StatelessWidget {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final recent = [...app.invoices]..sort((a, b) => b.issueDate.compareTo(a.issueDate));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              KpiCard(title: 'Overdue', value: formatCurrency(app.totalOverdue), icon: Icons.warning_amber_rounded, color: Colors.red),
              KpiCard(title: 'Due in 30 Days', value: formatCurrency(app.totalDueSoon), icon: Icons.schedule, color: Colors.orange),
              KpiCard(title: 'Paid Revenue', value: formatCurrency(app.totalPaid), icon: Icons.check_circle_outline, color: Colors.green),
              KpiCard(title: 'Total Invoices', value: '${app.invoices.length}', icon: Icons.receipt_long, color: const Color(0xFF3454D1)),
            ],
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Cashflow — Paid revenue (last 6 months)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 16),
                SizedBox(
                  height: 200,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: BarChartPainter(values: app.monthlyPaidTotals, labels: app.monthlyLabels),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Recent Invoices', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                for (final inv in recent.take(5))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined),
                    title: Text('${inv.invoiceNumber} · ${app.clientById(inv.clientId)?.name ?? "Unknown"}'),
                    subtitle: Text('Issued ${formatDate(inv.issueDate)} · Due ${formatDate(inv.dueDate)}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(formatCurrency(inv.grandTotal), style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 12),
                        StatusBadge(status: inv.displayStatusLabel),
                      ],
                    ),
                    onTap: () => showInvoicePreviewDialog(context, inv),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BarChartPainter extends CustomPainter {
  final List<double> values;
  final List<String> labels;
  BarChartPainter({required this.values, required this.labels});

  @override
  void paint(Canvas canvas, Size size) {
    final maxVal = values.isEmpty ? 1.0 : values.reduce(max);
    final safeMax = maxVal <= 0 ? 1.0 : maxVal;
    final barWidth = size.width / (values.length * 2);
    final barPaint = Paint()..color = const Color(0xFF3454D1);
    final axisPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, size.height - 24), Offset(size.width, size.height - 24), axisPaint);

    for (int i = 0; i < values.length; i++) {
      final barHeight = (values[i] / safeMax) * (size.height - 48);
      final x = barWidth * (i * 2 + 0.5);
      final rect = Rect.fromLTWH(x, size.height - 24 - barHeight, barWidth, barHeight);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), barPaint);

      final labelPainter = TextPainter(
        text: TextSpan(text: labels[i], style: TextStyle(color: Colors.grey.shade700, fontSize: 11)),
        textDirection: TextDirection.ltr,
      )..layout();
      labelPainter.paint(canvas, Offset(x + (barWidth - labelPainter.width) / 2, size.height - 20));
    }
  }

  @override
  bool shouldRepaint(covariant BarChartPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.labels != labels;
}

// =============================================================================
// SECTION: Invoices list
// =============================================================================

class InvoicesView extends StatefulWidget {
  final void Function({Invoice? existing, Invoice? aiDraft}) onOpenCreator;
  const InvoicesView({super.key, required this.onOpenCreator});

  @override
  State<InvoicesView> createState() => _InvoicesViewState();
}

class _InvoicesViewState extends State<InvoicesView> {
  String _query = '';
  String _statusFilter = 'All';

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    var list = [...app.invoices];
    if (_query.trim().isNotEmpty) {
      final q = _query.trim().toLowerCase();
      list = list.where((inv) {
        final clientName = app.clientById(inv.clientId)?.name.toLowerCase() ?? '';
        return inv.invoiceNumber.toLowerCase().contains(q) || clientName.contains(q);
      }).toList();
    }
    if (_statusFilter != 'All') {
      list = list.where((inv) => inv.displayStatusLabel == _statusFilter).toList();
    }
    list.sort((a, b) => b.issueDate.compareTo(a.issueDate));

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 320,
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search by invoice # or client…',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(width: 16),
              DropdownButton<String>(
                value: _statusFilter,
                items: ['All', 'Draft', 'Sent', 'Paid', 'Overdue']
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => setState(() => _statusFilter = v ?? 'All'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => widget.onOpenCreator(),
                icon: const Icon(Icons.add),
                label: const Text('New Invoice'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: list.isEmpty
                  ? const Center(child: Text('No invoices match your filters.'))
                  : SingleChildScrollView(
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Invoice #')),
                          DataColumn(label: Text('Client')),
                          DataColumn(label: Text('Issue Date')),
                          DataColumn(label: Text('Due Date')),
                          DataColumn(label: Text('Amount')),
                          DataColumn(label: Text('Status')),
                          DataColumn(label: Text('Actions')),
                        ],
                        rows: [
                          for (final inv in list)
                            DataRow(cells: [
                              DataCell(Text(inv.invoiceNumber)),
                              DataCell(Text(app.clientById(inv.clientId)?.name ?? 'Unknown')),
                              DataCell(Text(formatDate(inv.issueDate))),
                              DataCell(Text(formatDate(inv.dueDate))),
                              DataCell(Text(formatCurrency(inv.grandTotal))),
                              DataCell(StatusBadge(status: inv.displayStatusLabel)),
                              DataCell(Row(
                                children: [
                                  IconButton(
                                    tooltip: 'Preview',
                                    icon: const Icon(Icons.visibility_outlined, size: 18),
                                    onPressed: () => showInvoicePreviewDialog(context, inv),
                                  ),
                                  IconButton(
                                    tooltip: 'Edit',
                                    icon: const Icon(Icons.edit_outlined, size: 18),
                                    onPressed: () => widget.onOpenCreator(existing: inv),
                                  ),
                                  if (inv.status == InvoiceStatus.draft)
                                    IconButton(
                                      tooltip: 'Mark as Sent',
                                      icon: const Icon(Icons.send_outlined, size: 18),
                                      onPressed: () => app.sendInvoice(inv.id),
                                    ),
                                  if (inv.status != InvoiceStatus.paid)
                                    IconButton(
                                      tooltip: 'Mark Paid',
                                      icon: const Icon(Icons.paid_outlined, size: 18),
                                      onPressed: () => app.markInvoicePaid(inv.id),
                                    ),
                                  IconButton(
                                    tooltip: 'Delete',
                                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                    onPressed: () => app.softDeleteInvoice(inv.id),
                                  ),
                                ],
                              )),
                            ]),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION: Invoice preview modal (with simulated UPI QR)
// =============================================================================

void showInvoicePreviewDialog(BuildContext context, Invoice inv) {
  final app = AppStateScope.of(context);
  final client = app.clientById(inv.clientId);
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(backgroundColor: Color(0xFF3454D1), child: Icon(Icons.auto_awesome, color: Colors.white)),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('AuraWave Business', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('billing@aurawave.demo', style: TextStyle(color: Colors.black54, fontSize: 12)),
                      ],
                    ),
                    const Spacer(),
                    Text(inv.invoiceNumber, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                const Divider(height: 32),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('BILL TO', style: TextStyle(fontSize: 11, color: Colors.black45, fontWeight: FontWeight.bold)),
                          Text(client?.name ?? 'Unknown client', style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (client != null && client.company.isNotEmpty) Text(client.company),
                          if (client != null && client.email.isNotEmpty) Text(client.email),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Issue Date: ${formatDate(inv.issueDate)}'),
                        Text('Due Date: ${formatDate(inv.dueDate)}'),
                        StatusBadge(status: inv.displayStatusLabel),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Table(
                  border: TableBorder.all(color: Colors.grey.shade200),
                  columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1.4), 3: FlexColumnWidth(1.4)},
                  children: [
                    const TableRow(
                      decoration: BoxDecoration(color: Color(0xFFF0F2FA)),
                      children: [
                        Padding(padding: EdgeInsets.all(8), child: Text('Item', style: TextStyle(fontWeight: FontWeight.bold))),
                        Padding(padding: EdgeInsets.all(8), child: Text('Qty', style: TextStyle(fontWeight: FontWeight.bold))),
                        Padding(padding: EdgeInsets.all(8), child: Text('Price', style: TextStyle(fontWeight: FontWeight.bold))),
                        Padding(padding: EdgeInsets.all(8), child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold))),
                      ],
                    ),
                    for (final item in inv.items)
                      TableRow(children: [
                        Padding(padding: const EdgeInsets.all(8), child: Text(item.name)),
                        Padding(padding: const EdgeInsets.all(8), child: Text(item.qty.toStringAsFixed(item.qty % 1 == 0 ? 0 : 2))),
                        Padding(padding: const EdgeInsets.all(8), child: Text(formatCurrency(item.unitPrice))),
                        Padding(padding: const EdgeInsets.all(8), child: Text(formatCurrency(item.lineTotal))),
                      ]),
                  ],
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 260,
                    child: Column(
                      children: [
                        _totalRow('Subtotal', formatCurrency(inv.subtotal)),
                        for (final entry in inv.taxBreakdown.entries) _totalRow('Tax ${entry.key}', formatCurrency(entry.value)),
                        const Divider(),
                        _totalRow('Grand Total', formatCurrency(inv.grandTotal), bold: true),
                      ],
                    ),
                  ),
                ),
                if (inv.notes.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Notes: ${inv.notes}', style: const TextStyle(color: Colors.black54, fontSize: 12)),
                ],
                const SizedBox(height: 20),
                Center(
                  child: Column(
                    children: [
                      CustomPaint(
                        size: const Size(120, 120),
                        painter: QrPainter(seed: inv.id.hashCode),
                      ),
                      const SizedBox(height: 6),
                      const Text('Scan to pay via UPI', style: TextStyle(fontSize: 11, color: Colors.black54)),
                      const Text('aurawave@upi', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Invoice exported as PDF (simulated).'))),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('Invoice downloaded as PDF (simulated).'))),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Download PDF'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _totalRow(String label, String value, {bool bold = false}) {
  final style = TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 16 : 13);
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label, style: style), Text(value, style: style)],
    ),
  );
}

class QrPainter extends CustomPainter {
  final int seed;
  QrPainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    const gridSize = 15;
    final cell = size.width / gridSize;
    final rand = Random(seed);
    final dark = Paint()..color = Colors.black87;
    final bg = Paint()..color = Colors.white;

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bg);

    for (int y = 0; y < gridSize; y++) {
      for (int x = 0; x < gridSize; x++) {
        final inFinder = (x < 4 && y < 4) || (x > gridSize - 5 && y < 4) || (x < 4 && y > gridSize - 5);
        if (inFinder) continue;
        if (rand.nextBool()) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), dark);
        }
      }
    }

    void finder(int gx, int gy) {
      canvas.drawRect(Rect.fromLTWH(gx * cell, gy * cell, cell * 4, cell * 4), dark);
      canvas.drawRect(Rect.fromLTWH((gx + 0.8) * cell, (gy + 0.8) * cell, cell * 2.4, cell * 2.4), bg);
      canvas.drawRect(Rect.fromLTWH((gx + 1.4) * cell, (gy + 1.4) * cell, cell * 1.2, cell * 1.2), dark);
    }

    finder(0, 0);
    finder(gridSize - 4, 0);
    finder(0, gridSize - 4);
  }

  @override
  bool shouldRepaint(covariant QrPainter oldDelegate) => oldDelegate.seed != seed;
}

// =============================================================================
// SECTION: Invoice creator
// =============================================================================

class InvoiceCreatorScreen extends StatefulWidget {
  final Invoice? existing;
  final Invoice? aiDraft;
  const InvoiceCreatorScreen({super.key, this.existing, this.aiDraft});

  @override
  State<InvoiceCreatorScreen> createState() => _InvoiceCreatorScreenState();
}

class _InvoiceCreatorScreenState extends State<InvoiceCreatorScreen> {
  late List<LineItem> _items;
  String? _clientId;
  late DateTime _issueDate;
  late DateTime _dueDate;
  final _notesCtrl = TextEditingController();
  bool _isEditing = false;
  bool _fromAi = false;
  String _invoiceId = '';
  String? _invoiceNumber;

  final Map<String, TextEditingController> _nameCtrls = {};
  final Map<String, TextEditingController> _qtyCtrls = {};
  final Map<String, TextEditingController> _priceCtrls = {};

  @override
  void initState() {
    super.initState();
    final source = widget.existing ?? widget.aiDraft;
    if (source != null) {
      _items = source.items.map((i) => i.copy()).toList();
      _clientId = source.clientId;
      _issueDate = source.issueDate;
      _dueDate = source.dueDate;
      _notesCtrl.text = source.notes;
      _invoiceId = widget.existing?.id ?? _newId('inv');
      _invoiceNumber = widget.existing?.invoiceNumber;
      _isEditing = widget.existing != null;
      _fromAi = widget.aiDraft != null;
    } else {
      _items = [LineItem(id: _newId('li'), name: '', qty: 1, unitPrice: 0, taxPercent: 18)];
      _issueDate = DateTime.now();
      _dueDate = DateTime.now().add(const Duration(days: 14));
      _invoiceId = _newId('inv');
    }
    if (widget.aiDraft != null) {
      // Consume the pending AI draft now that it has been loaded locally.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        AppStateScope.of(context).clearAiDraft();
      });
    }
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    for (final c in _nameCtrls.values) {
      c.dispose();
    }
    for (final c in _qtyCtrls.values) {
      c.dispose();
    }
    for (final c in _priceCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrlFor(Map<String, TextEditingController> map, String id, String initial) {
    return map.putIfAbsent(id, () => TextEditingController(text: initial));
  }

  double get _subtotal => _items.fold(0.0, (s, i) => s + i.lineSubtotal);
  double get _taxTotal => _items.fold(0.0, (s, i) => s + i.taxAmount);
  double get _grandTotal => _subtotal + _taxTotal;

  Map<String, double> get _taxBreakdown {
    final map = <String, double>{};
    for (final item in _items) {
      final key = '${item.taxPercent.toStringAsFixed(item.taxPercent % 1 == 0 ? 0 : 1)}%';
      map[key] = (map[key] ?? 0) + item.taxAmount;
    }
    return map;
  }

  void _addLineItem() {
    setState(() => _items.add(LineItem(id: _newId('li'), name: '', qty: 1, unitPrice: 0, taxPercent: 18)));
  }

  void _removeLineItem(String id) {
    setState(() {
      _items.removeWhere((i) => i.id == id);
      _nameCtrls.remove(id)?.dispose();
      _qtyCtrls.remove(id)?.dispose();
      _priceCtrls.remove(id)?.dispose();
    });
  }

  Future<void> _pickDate({required bool isIssue}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isIssue ? _issueDate : _dueDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked != null) {
      setState(() {
        if (isIssue) {
          _issueDate = picked;
        } else {
          _dueDate = picked;
        }
      });
    }
  }

  Future<void> _quickAddClient() async {
    final result = await showFormDialog(context, title: 'Add Client', fields: ['Name', 'Email', 'Phone', 'Company']);
    if (result == null || (result['Name'] ?? '').trim().isEmpty) return;
    final app = AppStateScope.of(context);
    final client = Client(
      id: _newId('cl'),
      name: result['Name']!.trim(),
      email: result['Email'] ?? '',
      phone: result['Phone'] ?? '',
      company: result['Company'] ?? '',
      address: '',
      createdAt: DateTime.now(),
    );
    app.addClient(client);
    setState(() => _clientId = client.id);
  }

  Future<void> _pickFromCatalog(LineItem item) async {
    final app = AppStateScope.of(context);
    final selected = await showDialog<Product>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pick from Catalog'),
        content: SizedBox(
          width: 340,
          height: 320,
          child: ListView(
            children: app.products
                .map((p) => ListTile(
                      title: Text(p.name),
                      subtitle: Text('${formatCurrency(p.defaultPrice)} · ${p.defaultTaxPercent.toStringAsFixed(0)}% GST'),
                      onTap: () => Navigator.pop(ctx, p),
                    ))
                .toList(),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
    if (selected == null) return;
    setState(() {
      item.name = selected.name;
      item.unitPrice = selected.defaultPrice;
      item.taxPercent = selected.defaultTaxPercent;
      _ctrlFor(_nameCtrls, item.id, item.name).text = item.name;
      _ctrlFor(_priceCtrls, item.id, item.unitPrice.toString()).text = item.unitPrice.toString();
    });
  }

  void _save({required InvoiceStatus status}) {
    if (_clientId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select a client.')));
      return;
    }
    final validItems = _items.where((i) => i.name.trim().isNotEmpty).toList();
    if (validItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add at least one line item.')));
      return;
    }
    final app = AppStateScope.of(context);
    final invoice = Invoice(
      id: _invoiceId,
      invoiceNumber: _invoiceNumber ?? app.generateInvoiceNumber(),
      clientId: _clientId!,
      issueDate: _issueDate,
      dueDate: _dueDate,
      items: validItems,
      status: status,
      notes: _notesCtrl.text.trim(),
      aiGenerated: _fromAi,
    );
    if (_isEditing) {
      app.updateInvoice(invoice);
    } else {
      app.addInvoice(invoice);
    }
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_isEditing ? 'Invoice updated.' : 'Invoice saved.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Invoice ${_invoiceNumber ?? ""}' : 'New Invoice'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_fromAi)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(color: Colors.amber.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.amber.shade200)),
                  child: Row(
                    children: const [
                      Icon(Icons.auto_awesome, color: Colors.amber, size: 18),
                      SizedBox(width: 8),
                      Expanded(child: Text('AI-generated draft — review the details below, then confirm.')),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _clientId,
                      decoration: const InputDecoration(labelText: 'Client', border: OutlineInputBorder()),
                      items: app.clients.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                      onChanged: (v) => setState(() => _clientId = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(onPressed: _quickAddClient, icon: const Icon(Icons.person_add_alt_1_outlined), tooltip: 'Add new client'),
                  const SizedBox(width: 16),
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(isIssue: true),
                    icon: const Icon(Icons.calendar_today_outlined, size: 16),
                    label: Text('Issue: ${formatDate(_issueDate)}'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _pickDate(isIssue: false),
                    icon: const Icon(Icons.event_outlined, size: 16),
                    label: Text('Due: ${formatDate(_dueDate)}'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text('Line Items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade200), borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    for (final item in _items) _buildLineItemRow(item),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(onPressed: _addLineItem, icon: const Icon(Icons.add), label: const Text('Add Line Item')),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _notesCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 280,
                  child: Column(
                    children: [
                      _totalRow('Subtotal', formatCurrency(_subtotal)),
                      for (final entry in _taxBreakdown.entries) _totalRow('Tax ${entry.key}', formatCurrency(entry.value)),
                      const Divider(),
                      _totalRow('Grand Total', formatCurrency(_grandTotal), bold: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      if (_clientId == null) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a client to preview.')));
                        return;
                      }
                      final previewInvoice = Invoice(
                        id: _invoiceId,
                        invoiceNumber: _invoiceNumber ?? 'DRAFT',
                        clientId: _clientId!,
                        issueDate: _issueDate,
                        dueDate: _dueDate,
                        items: _items.where((i) => i.name.trim().isNotEmpty).toList(),
                        status: InvoiceStatus.draft,
                        notes: _notesCtrl.text.trim(),
                      );
                      showInvoicePreviewDialog(context, previewInvoice);
                    },
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('Preview'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(onPressed: () => _save(status: InvoiceStatus.draft), child: const Text('Save as Draft')),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () => _save(status: InvoiceStatus.sent),
                    icon: Icon(_fromAi ? Icons.check : Icons.send),
                    label: Text(_fromAi ? 'Approve & Send' : (_isEditing ? 'Update & Send' : 'Save & Send')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLineItemRow(LineItem item) {
    final nameCtrl = _ctrlFor(_nameCtrls, item.id, item.name);
    final qtyCtrl = _ctrlFor(_qtyCtrls, item.id, item.qty == item.qty.roundToDouble() ? item.qty.toStringAsFixed(0) : item.qty.toString());
    final priceCtrl = _ctrlFor(_priceCtrls, item.id, item.unitPrice.toString());

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.shade100))),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(hintText: 'Item name', isDense: true, border: OutlineInputBorder()),
              onChanged: (v) => setState(() => item.name = v),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.list_alt_outlined, size: 18),
            tooltip: 'Pick from catalog',
            onPressed: () => _pickFromCatalog(item),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Qty', isDense: true, border: OutlineInputBorder()),
              onChanged: (v) => setState(() => item.qty = double.tryParse(v) ?? 0),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: priceCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Unit Price', isDense: true, border: OutlineInputBorder()),
              onChanged: (v) => setState(() => item.unitPrice = double.tryParse(v) ?? 0),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<double>(
              initialValue: kGstSlabs.contains(item.taxPercent) ? item.taxPercent : kGstSlabs.first,
              decoration: const InputDecoration(labelText: 'GST', isDense: true, border: OutlineInputBorder()),
              items: kGstSlabs.map((g) => DropdownMenuItem(value: g, child: Text('${g.toStringAsFixed(0)}%'))).toList(),
              onChanged: (v) => setState(() => item.taxPercent = v ?? 0),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text(formatCurrency(item.lineTotal), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.redAccent),
            onPressed: _items.length > 1 ? () => _removeLineItem(item.id) : null,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION: Clients directory
// =============================================================================

class ClientsView extends StatelessWidget {
  const ClientsView({super.key});

  Future<void> _addOrEdit(BuildContext context, {Client? existing}) async {
    final result = await showFormDialog(
      context,
      title: existing == null ? 'Add Client' : 'Edit Client',
      fields: ['Name', 'Email', 'Phone', 'Company', 'Address'],
      initial: existing == null
          ? null
          : {
              'Name': existing.name,
              'Email': existing.email,
              'Phone': existing.phone,
              'Company': existing.company,
              'Address': existing.address,
            },
    );
    if (result == null || (result['Name'] ?? '').trim().isEmpty) return;
    final app = AppStateScope.of(context);
    if (existing == null) {
      app.addClient(Client(
        id: _newId('cl'),
        name: result['Name']!.trim(),
        email: result['Email'] ?? '',
        phone: result['Phone'] ?? '',
        company: result['Company'] ?? '',
        address: result['Address'] ?? '',
        createdAt: DateTime.now(),
      ));
    } else {
      existing.name = result['Name']!.trim();
      existing.email = result['Email'] ?? '';
      existing.phone = result['Phone'] ?? '';
      existing.company = result['Company'] ?? '';
      existing.address = result['Address'] ?? '';
      app.updateClient(existing);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Customers / Clients', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton.icon(onPressed: () => _addOrEdit(context), icon: const Icon(Icons.add), label: const Text('Add Client')),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              childAspectRatio: 2.4,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
              children: [
                for (final c in app.clients)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3))],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            CircleAvatar(child: Text(c.name.isNotEmpty ? c.name[0] : '?')),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(c.name, style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                                  if (c.company.isNotEmpty) Text(c.company, style: const TextStyle(fontSize: 12, color: Colors.black54), overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Text(c.email, style: const TextStyle(fontSize: 12, color: Colors.black54), overflow: TextOverflow.ellipsis),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _addOrEdit(context, existing: c)),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                              onPressed: () => app.softDeleteClient(c.id),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION: Products catalog
// =============================================================================

class ProductsView extends StatelessWidget {
  const ProductsView({super.key});

  Future<void> _addOrEdit(BuildContext context, {Product? existing}) async {
    final result = await showFormDialog(
      context,
      title: existing == null ? 'Add Product / Service' : 'Edit Product / Service',
      fields: ['Name', 'Default Price', 'Default GST %', 'Unit'],
      initial: existing == null
          ? null
          : {
              'Name': existing.name,
              'Default Price': existing.defaultPrice.toString(),
              'Default GST %': existing.defaultTaxPercent.toString(),
              'Unit': existing.unit,
            },
    );
    if (result == null || (result['Name'] ?? '').trim().isEmpty) return;
    final app = AppStateScope.of(context);
    final price = double.tryParse(result['Default Price'] ?? '') ?? 0;
    final tax = double.tryParse(result['Default GST %'] ?? '') ?? 18;
    if (existing == null) {
      app.addProduct(Product(
        id: _newId('pr'),
        name: result['Name']!.trim(),
        defaultPrice: price,
        defaultTaxPercent: tax,
        unit: result['Unit'] ?? 'unit',
      ));
    } else {
      existing.name = result['Name']!.trim();
      existing.defaultPrice = price;
      existing.defaultTaxPercent = tax;
      existing.unit = result['Unit'] ?? existing.unit;
      app.updateProduct(existing);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Products / Services Catalog', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              FilledButton.icon(onPressed: () => _addOrEdit(context), icon: const Icon(Icons.add), label: const Text('Add Product')),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: ListView.separated(
                padding: const EdgeInsets.all(8),
                itemCount: app.products.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final p = app.products[i];
                  return ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.inventory_2_outlined)),
                    title: Text(p.name),
                    subtitle: Text('${formatCurrency(p.defaultPrice)} per ${p.unit} · ${p.defaultTaxPercent.toStringAsFixed(0)}% GST'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(icon: const Icon(Icons.edit_outlined, size: 18), onPressed: () => _addOrEdit(context, existing: p)),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                          onPressed: () => app.softDeleteProduct(p.id),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION: Recovery bin
// =============================================================================

class RecoveryBinView extends StatelessWidget {
  const RecoveryBinView({super.key});

  IconData _iconFor(RecordType t) {
    switch (t) {
      case RecordType.client:
        return Icons.person_outline;
      case RecordType.product:
        return Icons.inventory_2_outlined;
      case RecordType.invoice:
        return Icons.receipt_long_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final items = [...app.recycleBin]..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('30-Day Smart Recovery Bin', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Deleted items are kept for 30 days before permanent purge.', style: TextStyle(color: Colors.black54, fontSize: 12)),
          const SizedBox(height: 16),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('Recovery bin is empty.'))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final r = items[i];
                      final expired = r.daysRemaining <= 0;
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
                        ),
                        child: Row(
                          children: [
                            Icon(_iconFor(r.type), color: Colors.grey.shade600),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(r.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  Text('Deleted ${formatDate(r.deletedAt)} · ${r.type.name}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                ],
                              ),
                            ),
                            Text(
                              expired ? 'Expired' : '${r.daysRemaining} days left',
                              style: TextStyle(color: expired ? Colors.red : Colors.orange, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 16),
                            OutlinedButton.icon(
                              onPressed: () => app.restoreRecord(r.id),
                              icon: const Icon(Icons.restore, size: 16),
                              label: const Text('Restore'),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Purge permanently?'),
                                    content: Text('"${r.label}" will be permanently deleted. This cannot be undone.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                      FilledButton(
                                        style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: const Text('Purge'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirm == true) app.purgeRecord(r.id);
                              },
                              icon: const Icon(Icons.delete_forever_outlined, size: 16, color: Colors.redAccent),
                              label: const Text('Purge', style: TextStyle(color: Colors.redAccent)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION: Settings / Cloud sync center
// =============================================================================

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  bool _syncing = false;
  double _ingestProgress = 0;
  Timer? _ingestTimer;
  bool _ingesting = false;

  @override
  void dispose() {
    _ingestTimer?.cancel();
    super.dispose();
  }

  Future<void> _syncNow(AppState app) async {
    setState(() => _syncing = true);
    await app.syncNow();
    if (!mounted) return;
    setState(() => _syncing = false);
    final targets = [
      if (app.primaryDriveSync) 'Primary Drive',
      if (app.backupDriveSync) 'Backup Drive',
    ];
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(targets.isEmpty ? 'No sync targets enabled.' : 'Synced to ${targets.join(" & ")}.')),
    );
  }

  void _exportJson(AppState app) {
    final json = app.exportJson();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Encrypted Export (AES-256 simulated)'),
        content: SizedBox(
          width: 480,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(json, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard.')));
            },
            child: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup "${result.files.first.name}" imported (simulated).')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File picker unavailable on this platform — import simulated.')),
      );
    }
  }

  void _simulateHeavyIngest() {
    if (_ingesting) return;
    setState(() {
      _ingesting = true;
      _ingestProgress = 0;
    });
    _ingestTimer = Timer.periodic(const Duration(milliseconds: 60), (t) {
      setState(() => _ingestProgress += 0.02);
      if (_ingestProgress >= 1) {
        t.cancel();
        setState(() => _ingesting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Streaming ingestion complete — 1,204 records parsed at a steady 60 FPS.')),
        );
      }
    });
  }

  Future<void> _addSubClient(AppState app) async {
    final result = await showFormDialog(context, title: 'Add Sub-Client Profile', fields: ['Name', 'Email']);
    if (result == null || (result['Name'] ?? '').trim().isEmpty) return;
    app.addSubClient(result['Name']!.trim(), result['Email'] ?? '');
  }

  Future<void> _changePin(AppState app) async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    String? error;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Change PIN'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: currentCtrl, obscureText: true, maxLength: 6, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Current PIN')),
                TextField(controller: newCtrl, obscureText: true, maxLength: 6, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'New PIN')),
                TextField(controller: confirmCtrl, obscureText: true, maxLength: 6, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Confirm New PIN')),
                if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (!app.verifyPin(currentCtrl.text)) {
                  setDialogState(() => error = 'Current PIN is incorrect.');
                  return;
                }
                if (newCtrl.text.length != 6 || newCtrl.text != confirmCtrl.text) {
                  setDialogState(() => error = 'New PIN must be 6 digits and match confirmation.');
                  return;
                }
                app.setupPin(newCtrl.text);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN updated.')));
              },
              child: const Text('Update PIN'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionCard({required String title, required List<Widget> children}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionCard(title: 'Dual Cloud Sync', children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Primary Google Drive'),
                subtitle: const Text('Continuous encrypted sync'),
                value: app.primaryDriveSync,
                onChanged: (v) => setState(() => app.primaryDriveSync = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Backup Google Drive'),
                subtitle: const Text('Secondary redundant instance'),
                value: app.backupDriveSync,
                onChanged: (v) => setState(() => app.backupDriveSync = v),
              ),
              const SizedBox(height: 8),
              if (_syncing) const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _syncing ? null : () => _syncNow(app),
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync Snapshot Now'),
                  ),
                  OutlinedButton.icon(onPressed: () => _exportJson(app), icon: const Icon(Icons.upload_file_outlined), label: const Text('Export Encrypted JSON')),
                  OutlinedButton.icon(onPressed: _importBackup, icon: const Icon(Icons.download_for_offline_outlined), label: const Text('Import Backup')),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                app.lastSyncTime == null ? 'No sync recorded yet.' : 'Last sync: ${formatDate(app.lastSyncTime!)} at ${DateFormat('hh:mm a').format(app.lastSyncTime!)}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const Text('Data-in-transit secured via simulated TLS 1.3 / HTTPS.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
            _sectionCard(title: 'Heavy Dataset Handling', children: [
              const Text('Simulates chunked streaming ingestion for very large datasets (1GB–100GB) while keeping the UI responsive.', style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 12),
              if (_ingesting) LinearProgressIndicator(value: _ingestProgress),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _ingesting ? null : _simulateHeavyIngest,
                icon: const Icon(Icons.storage_outlined),
                label: Text(_ingesting ? 'Streaming… ${(_ingestProgress * 100).clamp(0, 100).toStringAsFixed(0)}%' : 'Simulate 25GB Dataset Ingestion'),
              ),
            ]),
            _sectionCard(title: 'Master-Client Management', children: [
              for (final s in app.subClients)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(child: Icon(Icons.badge_outlined)),
                  title: Text(s.name),
                  subtitle: Text('${s.email.isEmpty ? "No email set" : s.email} · Storage: ${s.storageId}'),
                  trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => app.removeSubClient(s.id)),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: () => _addSubClient(app), icon: const Icon(Icons.add), label: const Text('Add Sub-Client Profile')),
              ),
            ]),
            _sectionCard(title: 'Security', children: [
              Wrap(spacing: 12, runSpacing: 12, children: [
                OutlinedButton.icon(onPressed: () => _changePin(app), icon: const Icon(Icons.password_outlined), label: const Text('Change PIN')),
                OutlinedButton.icon(onPressed: () => app.lock(), icon: const Icon(Icons.lock_outline), label: const Text('Lock App Now')),
              ]),
            ]),
            _sectionCard(title: 'Privacy — Zero-Knowledge Mode', children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Telemetry'),
                subtitle: Text('telemetry: ${app.telemetryEnabled}'),
                value: app.telemetryEnabled,
                onChanged: (v) => setState(() => app.telemetryEnabled = v),
              ),
              const Text('PII auto-redaction is always active during Gemini Vision extraction.', style: TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
            _sectionCard(title: 'Regional Settings', children: [
              Text('Location: ${app.city}, ${app.state}, ${app.country}'),
              Text('Language: ${app.language}'),
              Text('Primary Gmail: ${app.primaryGmail}'),
              Text('Backup Gmail: ${app.backupGmail}'),
            ]),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SECTION: Voice pilot
// =============================================================================

const List<String> kSampleVoiceCommands = [
  'Create invoice for Rajesh: 2 web designs at 5000 each with 18% GST',
  'Create invoice for Meera Nair: 1 logo brand identity at 15000 each with 18% GST',
  'Create invoice for Arjun Singh: 5 consulting hourly at 2500 each with 18% GST',
];

void showVoicePilotSheet(BuildContext context, {required void Function(Invoice) onDraftReady}) {
  final commandCtrl = TextEditingController();
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: StatefulBuilder(
        builder: (ctx, setSheetState) {
          bool listening = false;

          Future<void> process(String command) async {
            setSheetState(() => listening = true);
            await Future.delayed(const Duration(milliseconds: 900));
            final app = AppStateScope.of(context);
            final draft = app.simulateVoiceCommand(command);
            if (ctx.mounted) Navigator.pop(ctx);
            onDraftReady(draft);
          }

          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.mic, color: Color(0xFF3454D1)),
                    SizedBox(width: 8),
                    Text('AuraWave Voice Pilot', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Tap a sample command or type your own — AuraWave drafts an editable invoice instantly.', style: TextStyle(color: Colors.black54)),
                const SizedBox(height: 16),
                if (listening)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Listening & drafting…'),
                      ],
                    ),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final cmd in kSampleVoiceCommands)
                        ActionChip(
                          label: Text(cmd, style: const TextStyle(fontSize: 12)),
                          onPressed: () => process(cmd),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: commandCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Or type a custom command',
                      hintText: 'Create invoice for Client: 3 items at 1000 each with 18% GST',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: () => process(commandCtrl.text.trim().isEmpty ? kSampleVoiceCommands.first : commandCtrl.text.trim()),
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Process Command'),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    ),
  );
}

// =============================================================================
// SECTION: Vision intake
// =============================================================================

void showVisionIntakeDialog(BuildContext context, {required void Function(Invoice) onDraftReady}) {
  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        String? fileName;
        bool scanning = false;
        bool scanned = false;

        Future<void> pickFile() async {
          try {
            final result = await FilePicker.platform.pickFiles(type: FileType.any);
            if (result == null || result.files.isEmpty) return;
            setDialogState(() {
              fileName = result.files.first.name;
              scanning = true;
              scanned = false;
            });
          } catch (_) {
            setDialogState(() {
              fileName = 'receipt_scan.jpg';
              scanning = true;
              scanned = false;
            });
          }
          await Future.delayed(const Duration(milliseconds: 1200));
          setDialogState(() {
            scanning = false;
            scanned = true;
          });
        }

        return AlertDialog(
          title: const Text('Gemini Vision Intake'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Upload a receipt image or a tabular data dump. Gemini 1.5 Flash Vision (simulated) will extract line items and auto-redact any PII.', style: TextStyle(color: Colors.black54, fontSize: 13)),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: scanning ? null : pickFile,
                  icon: const Icon(Icons.upload_file_outlined),
                  label: Text(fileName == null ? 'Choose File' : 'Re-scan "$fileName"'),
                ),
                const SizedBox(height: 16),
                if (scanning) const Column(children: [LinearProgressIndicator(), SizedBox(height: 8), Text('Parsing document…')]),
                if (scanned) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey.shade200)),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Extracted Fields', style: TextStyle(fontWeight: FontWeight.bold)),
                        SizedBox(height: 6),
                        Text('• Consulting (hourly) — 3 × ₹2,500'),
                        Text('• Cloud Hosting (monthly) — 1 × ₹1,800'),
                        SizedBox(height: 8),
                        Text('Aadhaar: [Aadhaar Redacted]', style: TextStyle(fontSize: 12, color: Colors.black45)),
                        Text('UPI RRN: [RRN Omitted]', style: TextStyle(fontSize: 12, color: Colors.black45)),
                        Text('Phone: [Redacted]', style: TextStyle(fontSize: 12, color: Colors.black45)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Discard')),
            FilledButton.icon(
              onPressed: scanned
                  ? () {
                      final app = AppStateScope.of(context);
                      final draft = app.simulateVisionExtraction(fileName ?? 'document');
                      Navigator.pop(ctx);
                      onDraftReady(draft);
                    }
                  : null,
              icon: const Icon(Icons.check),
              label: const Text('Confirm & Create Draft'),
            ),
          ],
        );
      },
    ),
  );
}
