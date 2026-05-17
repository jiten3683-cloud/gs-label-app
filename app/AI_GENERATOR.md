# AI Label Generator

A "describe-your-label" feature that lets users build templates in plain English instead of dragging elements.

```
User types:  "Gold ring 22K with net weight, serial and QR code"
                              │
                              ▼
                       AiService.generate()
                       ├── Claude API (if key set + online)
                       └── Rule-based pattern library (offline fallback)
                              │
                              ▼
                List<Map<String,dynamic>>  ──►  designer canvas + DbService
```

## Files added
- `lib/services/ai_service.dart` — the service. Two backends: Claude via `api.anthropic.com` (model `claude-haiku-4-5-20251001`, ~$0.001 per label) and a built-in pattern library for offline use.
- `lib/widgets/ai_generate_dialog.dart` — the UI dialog with prompt box, example chips, key management, and regenerate.

## Wire it into the Designer (1 minute)

Add an import and a button to your Designer's toolbar. Open `lib/pages/designer_page.dart` and:

**1. Add the import at the top:**
```dart
import '../widgets/ai_generate_dialog.dart';
```

**2. Add an "AI" button to the header / toolbar.** Drop this in next to the Save button:
```dart
FilledButton.tonalIcon(
  onPressed: _aiGenerate,
  icon: const Icon(Icons.auto_awesome),
  label: const Text('AI'),
),
```

**3. Add this handler in the state class** (replaces the current elements with what the AI returned):
```dart
Future<void> _aiGenerate() async {
  final result = await showDialog<List<Map<String, dynamic>>>(
    context: context,
    builder: (_) => AiGenerateDialog(widthMm: _wMm, heightMm: _hMm),
  );
  if (result == null || result.isEmpty) return;

  setState(() {
    _elements
      ..clear()
      ..addAll(result.map(_fromMap));   // your existing _fromMap helper
    _selected = _elements.isNotEmpty ? _elements.first : null;
  });

  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Loaded ${result.length} elements from AI')));
}
```

That's it. Run the app, switch to Designer, tap **AI**.

## How users get a Claude API key

The dialog has a key icon in the top-right that opens a paste-your-key prompt. To get one:

1. Go to <https://console.anthropic.com/settings/keys>
2. Sign in (or sign up if new — same account as claude.ai works).
3. Click **Create Key**, name it "GS Label App".
4. Copy the key (starts with `sk-ant-…`).
5. Paste it into the app's AI dialog → key icon.

The key is stored in `SharedPreferences` on the phone. It never leaves the device except when calling `api.anthropic.com` directly.

## Cost expectations

Using `claude-haiku-4-5` (cheap + fast model):

| Operation | Tokens in | Tokens out | Approx cost |
|---|---|---|---|
| One label generation | ~600 | ~400 | **~$0.0008 (₹0.07)** |
| 100 labels/day | — | — | **~$0.08/day (₹6)** |
| 3000 labels/month | — | — | **~$2.40/month (₹200)** |

That's far cheaper than what a single labelled item is worth. If the cost worries you for production, set up a proxy backend (see "Production deployment" below).

## Offline mode (no key)

If the user doesn't set a key, the dialog still works — it falls back to the rule-based generator. The patterns recognise keywords in the prompt:

| Keyword in prompt | Pattern returned |
|---|---|
| `ring` (default) | Heading, big net weight, serial, datetime, small QR |
| `chain` | Heading, gross + net, serial, large QR |
| `bangle` / `kada` | Heading, big net, serial, datetime, QR |
| `coin` / `biscuit` | Centered heading, big weight, serial, Code 128 |
| `bar` / `bullion` | "FINE GOLD 999" heading, large weight, serial, barcode |

Adding more patterns is trivial — drop a new `_pattern<Name>` function in `ai_service.dart` and add a keyword check at the top of `_ruleBased`.

## Production deployment (later)

Asking each user to paste an API key won't scale. When you ship to multiple shops:

1. **Deploy a tiny proxy backend** (50 lines of Cloudflare Worker / Render / Fly.io). It holds *your* Anthropic key and proxies the chat completion call.
2. Replace `_endpoint` in `ai_service.dart` with your proxy URL.
3. Replace the `x-api-key` header with a per-shop license key your backend recognises.
4. Now you bill the shop monthly and absorb the Claude cost yourself.

I can write the proxy when you're ready — it's a one-pager.

## Next steps (v2)

The dialog is wired so we can extend it without breaking anything:
- **Follow-up edits** ("make the weight bigger") — send the current element list back to Claude with the modification request.
- **Photo input** — let the user snap a competitor's tag, send the image to Claude with the vision API, get back a matching template.
- **Auto-generate on first launch** — when a new user opens the app, generate a starter template based on shop type from a 3-question wizard.
