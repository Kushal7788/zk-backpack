import 'dart:convert';

/// A user's choice of what subset of a proof's revealed body to expose
/// when a share token is opened.
class ShareSelection {
  const ShareSelection({
    this.fields = const <RevealField>[],
    this.predicates = const <RevealPredicate>[],
  });

  final List<RevealField> fields;
  final List<RevealPredicate> predicates;

  bool get isEmpty => fields.isEmpty && predicates.isEmpty;

  ShareSelection copyWith({
    List<RevealField>? fields,
    List<RevealPredicate>? predicates,
  }) {
    return ShareSelection(
      fields: fields ?? this.fields,
      predicates: predicates ?? this.predicates,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'fields': fields.map((field) => field.toJson()).toList(growable: false),
    'predicates':
        predicates.map((predicate) => predicate.toJson()).toList(growable: false),
  };

  factory ShareSelection.fromJson(Map<String, Object?> json) {
    final fields = (json['fields'] as List<Object?>? ?? const <Object?>[])
        .whereType<Map<String, Object?>>()
        .map(RevealField.fromJson)
        .toList(growable: false);
    final predicates =
        (json['predicates'] as List<Object?>? ?? const <Object?>[])
            .whereType<Map<String, Object?>>()
            .map(RevealPredicate.fromJson)
            .toList(growable: false);
    return ShareSelection(fields: fields, predicates: predicates);
  }

  @override
  String toString() => jsonEncode(toJson());
}

class RevealField {
  const RevealField({required this.path, required this.label});

  final String path;
  final String label;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'label': label,
  };

  factory RevealField.fromJson(Map<String, Object?> json) {
    return RevealField(
      path: (json['path'] as String?)?.trim() ?? '',
      label: (json['label'] as String?)?.trim() ?? '',
    );
  }
}

/// Predicate evaluated against the proof contents.
/// A predicate transforms a single source value (e.g. DOB string → age in years)
/// and compares it against `value` using `op`.
class RevealPredicate {
  const RevealPredicate({
    required this.id,
    required this.label,
    required this.sourcePath,
    required this.transform,
    required this.op,
    required this.value,
    this.value2,
  });

  final String id;
  final String label;
  final String sourcePath;
  // Identifier for a server-side transform. See selection_evaluator.dart.
  // Current values: identity, dateToYearsTillNow, parseNumber, length,
  // digitsOnly. Older builds may also emit dobToAgeYears, parseInt,
  // lower, upper, or extractDigits; those continue to evaluate identically
  // to their modern counterparts.
  final String transform;
  // Allowed: ==, !=, >, >=, <, <=, between, contains, startsWith, endsWith.
  final String op;
  final Object? value;
  final Object? value2;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'sourcePath': sourcePath,
    'transform': transform,
    'op': op,
    'value': value,
    if (value2 != null) 'value2': value2,
  };

  factory RevealPredicate.fromJson(Map<String, Object?> json) {
    return RevealPredicate(
      id: (json['id'] as String?)?.trim() ?? '',
      label: (json['label'] as String?)?.trim() ?? '',
      sourcePath: (json['sourcePath'] as String?)?.trim() ?? '',
      transform: (json['transform'] as String?)?.trim() ?? 'identity',
      op: (json['op'] as String?)?.trim() ?? '==',
      value: json['value'],
      value2: json['value2'],
    );
  }
}
