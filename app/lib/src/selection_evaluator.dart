import 'share_selection.dart';

class FieldResult {
  const FieldResult({
    required this.label,
    required this.path,
    required this.value,
  });

  final String label;
  final String path;
  final Object? value;
}

class PredicateResult {
  const PredicateResult({
    required this.id,
    required this.label,
    required this.expression,
    required this.satisfied,
    required this.evaluable,
    this.reason,
  });

  final String id;
  final String label;
  final String expression;
  final bool satisfied;
  final bool evaluable;
  final String? reason;
}

class SelectionEvaluation {
  const SelectionEvaluation({required this.fields, required this.predicates});

  final List<FieldResult> fields;
  final List<PredicateResult> predicates;

  Map<String, Object?> toJson() => <String, Object?>{
    'fields': <String, Object?>{
      for (final entry in fields) entry.label: entry.value,
    },
    'predicates': predicates
        .map(
          (predicate) => <String, Object?>{
            'id': predicate.id,
            'label': predicate.label,
            'expression': predicate.expression,
            'satisfied': predicate.satisfied,
            'evaluable': predicate.evaluable,
            if (predicate.reason != null) 'reason': predicate.reason,
          },
        )
        .toList(growable: false),
  };
}

/// Looks up a value inside a revealedBody-style map.
/// Supports keys that are either plain field names, or already JSONPath-shaped
/// like `$.responseData.demographicsInfo.dob`. For dot-paths we first try the
/// exact map key (some proof payloads store them this way), and fall back to a true
/// nested lookup if needed.
Object? lookupValue(Map<String, Object?> revealed, String path) {
  if (revealed.containsKey(path)) {
    return revealed[path];
  }
  var cleaned = path.trim();
  if (cleaned.startsWith(r'$.')) {
    cleaned = cleaned.substring(2);
  } else if (cleaned.startsWith(r'$')) {
    cleaned = cleaned.substring(1);
  }
  if (revealed.containsKey(cleaned)) {
    return revealed[cleaned];
  }
  Object? cursor = revealed;
  for (final segment in cleaned.split('.')) {
    if (segment.isEmpty) continue;
    if (cursor is Map<String, Object?> && cursor.containsKey(segment)) {
      cursor = cursor[segment];
    } else {
      return null;
    }
  }
  return cursor;
}

/// Returns the body to evaluate against. We accept either a full proof
/// artifact (`{payload: {response: {revealedBody: ...}}}`) or the
/// revealedBody map directly.
Map<String, Object?> resolveRevealedBody(Object? raw) {
  if (raw is Map<String, Object?>) {
    final payload = raw['payload'];
    if (payload is Map<String, Object?>) {
      final response = payload['response'];
      if (response is Map<String, Object?>) {
        final revealed = response['revealedBody'];
        if (revealed is Map<String, Object?>) {
          return revealed;
        }
      }
    }
    return raw;
  }
  return const <String, Object?>{};
}

Object? applyTransform(String transform, Object? input) {
  if (input == null) return null;
  switch (transform) {
    case 'identity':
    case '':
      return input;
    case 'dateToYearsTillNow':
    // Legacy alias kept so share records minted by older builds keep
    // evaluating identically.
    case 'dobToAgeYears':
      return _dateToYearsTillNow(input);
    case 'parseNumber':
    // `parseInt` removed from the editor UI but still accepted here so
    // historical predicates stay valid.
    case 'parseInt':
      if (input is num) return input;
      return double.tryParse(input.toString().trim());
    case 'length':
      return input.toString().length;
    case 'digitsOnly':
    case 'extractDigits':
      return input.toString().replaceAll(RegExp(r'[^0-9]'), '');
    // Case-folding transforms — no longer offered in the UI since string
    // comparison is now case-insensitive by default. Kept as aliases so
    // older share records continue to behave the way they were minted.
    case 'lower':
      return input.toString().toLowerCase();
    case 'upper':
      return input.toString().toUpperCase();
    default:
      return input;
  }
}

int? _dateToYearsTillNow(Object? input) {
  if (input == null) return null;
  final raw = input.toString().trim();
  if (raw.isEmpty) return null;
  // Try ISO YYYY-MM-DD(THH:MM…) first, then DD-MM-YYYY or DD/MM/YYYY.
  DateTime? date = DateTime.tryParse(raw);
  if (date == null) {
    final match = RegExp(
      r'^(\d{1,2})[\-/](\d{1,2})[\-/](\d{4})$',
    ).firstMatch(raw);
    if (match != null) {
      final day = int.tryParse(match.group(1)!);
      final month = int.tryParse(match.group(2)!);
      final year = int.tryParse(match.group(3)!);
      if (day != null && month != null && year != null) {
        date = DateTime(year, month, day);
      }
    }
  }
  if (date == null) return null;
  final now = DateTime.now().toUtc();
  if (date.isAfter(now)) return null;
  var years = now.year - date.year;
  final hasHadAnniversary =
      now.month > date.month ||
      (now.month == date.month && now.day >= date.day);
  if (!hasHadAnniversary) years -= 1;
  return years;
}

bool _truthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  return true;
}

int _compare(Object? a, Object? b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is num) {
    final parsed = double.tryParse(b?.toString() ?? '');
    if (parsed != null) return a.compareTo(parsed);
  }
  if (b is num) {
    final parsed = double.tryParse(a?.toString() ?? '');
    if (parsed != null) return parsed.compareTo(b);
  }
  // String comparison is case-insensitive so the predicate UI no longer
  // needs a lower/upper transform — `name == "Ada"` matches `"ADA"`.
  final left = (a ?? '').toString().toLowerCase();
  final right = (b ?? '').toString().toLowerCase();
  return left.compareTo(right);
}

PredicateResult evaluatePredicate(
  RevealPredicate predicate,
  Map<String, Object?> revealedBody,
) {
  final raw = lookupValue(revealedBody, predicate.sourcePath);
  if (raw == null) {
    return PredicateResult(
      id: predicate.id,
      label: predicate.label,
      expression: _buildExpression(predicate),
      satisfied: false,
      evaluable: false,
      reason: 'source field "${predicate.sourcePath}" not found in proof',
    );
  }
  final transformed = applyTransform(predicate.transform, raw);
  if (transformed == null) {
    return PredicateResult(
      id: predicate.id,
      label: predicate.label,
      expression: _buildExpression(predicate),
      satisfied: false,
      evaluable: false,
      reason: 'transform "${predicate.transform}" could not parse value',
    );
  }
  final bool satisfied;
  switch (predicate.op) {
    case '==':
      satisfied = _compare(transformed, predicate.value) == 0;
      break;
    case '!=':
      satisfied = _compare(transformed, predicate.value) != 0;
      break;
    case '>':
      satisfied = _compare(transformed, predicate.value) > 0;
      break;
    case '>=':
      satisfied = _compare(transformed, predicate.value) >= 0;
      break;
    case '<':
      satisfied = _compare(transformed, predicate.value) < 0;
      break;
    case '<=':
      satisfied = _compare(transformed, predicate.value) <= 0;
      break;
    case 'between':
      satisfied =
          _compare(transformed, predicate.value) >= 0 &&
          _compare(transformed, predicate.value2) <= 0;
      break;
    case 'contains':
      satisfied = transformed.toString().toLowerCase().contains(
        (predicate.value ?? '').toString().toLowerCase(),
      );
      break;
    case 'startsWith':
      satisfied = transformed.toString().toLowerCase().startsWith(
        (predicate.value ?? '').toString().toLowerCase(),
      );
      break;
    case 'endsWith':
      satisfied = transformed.toString().toLowerCase().endsWith(
        (predicate.value ?? '').toString().toLowerCase(),
      );
      break;
    case 'truthy':
      satisfied = _truthy(transformed);
      break;
    default:
      return PredicateResult(
        id: predicate.id,
        label: predicate.label,
        expression: _buildExpression(predicate),
        satisfied: false,
        evaluable: false,
        reason: 'unsupported operator "${predicate.op}"',
      );
  }
  return PredicateResult(
    id: predicate.id,
    label: predicate.label,
    expression: _buildExpression(predicate),
    satisfied: satisfied,
    evaluable: true,
  );
}

String _buildExpression(RevealPredicate predicate) {
  final lhs = predicate.transform == 'identity' || predicate.transform.isEmpty
      ? predicate.sourcePath
      : '${predicate.transform}(${predicate.sourcePath})';
  if (predicate.op == 'between') {
    return '$lhs in [${predicate.value}, ${predicate.value2}]';
  }
  if (predicate.op == 'truthy') {
    return '$lhs is truthy';
  }
  return '$lhs ${predicate.op} ${predicate.value}';
}

SelectionEvaluation evaluateSelection(
  ShareSelection selection,
  Object? artifactOrRevealedBody,
) {
  final revealed = resolveRevealedBody(artifactOrRevealedBody);
  final fields = <FieldResult>[];
  for (final field in selection.fields) {
    final value = lookupValue(revealed, field.path);
    fields.add(
      FieldResult(
        label: field.label.isNotEmpty ? field.label : field.path,
        path: field.path,
        value: value,
      ),
    );
  }
  final predicates = <PredicateResult>[];
  for (final predicate in selection.predicates) {
    predicates.add(evaluatePredicate(predicate, revealed));
  }
  return SelectionEvaluation(fields: fields, predicates: predicates);
}
