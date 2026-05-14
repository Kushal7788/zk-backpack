// Server-side mirror of zk_backpack/app/lib/src/selection_evaluator.dart.
// Evaluates a ShareSelection against a decrypted proof artifact and returns
// only the fields and predicate outcomes the owner explicitly chose to expose.

export function resolveRevealedBody(input) {
  if (!input || typeof input !== 'object') return {};
  const payload = input.payload;
  if (payload && typeof payload === 'object') {
    const response = payload.response;
    if (response && typeof response === 'object') {
      const revealed = response.revealedBody;
      if (revealed && typeof revealed === 'object') {
        return revealed;
      }
    }
  }
  return input;
}

export function lookupValue(revealed, path) {
  if (!revealed || typeof revealed !== 'object') return undefined;
  if (Object.prototype.hasOwnProperty.call(revealed, path)) {
    return revealed[path];
  }
  let cleaned = String(path ?? '').trim();
  if (cleaned.startsWith('$.')) cleaned = cleaned.slice(2);
  else if (cleaned.startsWith('$')) cleaned = cleaned.slice(1);
  if (Object.prototype.hasOwnProperty.call(revealed, cleaned)) {
    return revealed[cleaned];
  }
  let cursor = revealed;
  for (const segment of cleaned.split('.')) {
    if (!segment) continue;
    if (cursor && typeof cursor === 'object' && segment in cursor) {
      cursor = cursor[segment];
    } else {
      return undefined;
    }
  }
  return cursor;
}

function dateToYearsTillNow(value) {
  if (value == null) return null;
  const raw = String(value).trim();
  if (!raw) return null;
  let date = new Date(raw);
  if (Number.isNaN(date.getTime())) {
    const match = /^(\d{1,2})[\-\/](\d{1,2})[\-\/](\d{4})$/.exec(raw);
    if (match) {
      const [, d, m, y] = match;
      date = new Date(Number(y), Number(m) - 1, Number(d));
    }
  }
  if (Number.isNaN(date.getTime())) return null;
  const now = new Date();
  if (date.getTime() > now.getTime()) return null;
  let years = now.getUTCFullYear() - date.getUTCFullYear();
  const hasHadAnniversary =
    now.getUTCMonth() > date.getUTCMonth() ||
    (now.getUTCMonth() === date.getUTCMonth() &&
      now.getUTCDate() >= date.getUTCDate());
  if (!hasHadAnniversary) years -= 1;
  return years;
}

export function applyTransform(transform, input) {
  if (input == null) return null;
  switch (transform) {
    case '':
    case 'identity':
      return input;
    case 'dateToYearsTillNow':
    // Legacy alias retained so historical share records keep evaluating.
    case 'dobToAgeYears':
      return dateToYearsTillNow(input);
    case 'parseNumber':
    // `parseInt` is no longer offered in the editor (numbers cover ints
    // and floats). Kept here as a silent alias.
    case 'parseInt': {
      if (typeof input === 'number') return input;
      const n = Number(String(input).trim());
      return Number.isFinite(n) ? n : null;
    }
    case 'length':
      return String(input).length;
    case 'digitsOnly':
    case 'extractDigits':
      return String(input).replace(/[^0-9]/g, '');
    // Case-folding transforms removed from the UI since string compare
    // is now case-insensitive. Kept as aliases for backward compatibility.
    case 'lower':
      return String(input).toLowerCase();
    case 'upper':
      return String(input).toUpperCase();
    default:
      return input;
  }
}

function compare(a, b) {
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  if (typeof a === 'number') {
    const n = Number(b);
    if (Number.isFinite(n)) return a - n;
  }
  if (typeof b === 'number') {
    const n = Number(a);
    if (Number.isFinite(n)) return n - b;
  }
  // Case-insensitive locale compare so `==`, `>=`, etc. on strings no
  // longer require a separate lower/upper transform.
  const left = String(a ?? '');
  const right = String(b ?? '');
  return left.localeCompare(right, undefined, { sensitivity: 'accent' });
}

function evaluatePredicate(predicate, revealed) {
  const label = predicate.label || 'Predicate';
  const sourcePath = predicate.sourcePath || '';
  const expression = buildExpression(predicate);
  const raw = lookupValue(revealed, sourcePath);
  if (raw === undefined || raw === null) {
    return {
      id: predicate.id || '',
      label,
      expression,
      satisfied: false,
      evaluable: false,
      reason: `source field "${sourcePath}" not found in proof`
    };
  }
  const transformed = applyTransform(predicate.transform || 'identity', raw);
  if (transformed === null || transformed === undefined) {
    return {
      id: predicate.id || '',
      label,
      expression,
      satisfied: false,
      evaluable: false,
      reason: `transform "${predicate.transform}" could not parse value`
    };
  }
  const op = predicate.op || '==';
  const value = predicate.value;
  const value2 = predicate.value2;
  let satisfied = false;
  switch (op) {
    case '==':
      satisfied = compare(transformed, value) === 0;
      break;
    case '!=':
      satisfied = compare(transformed, value) !== 0;
      break;
    case '>':
      satisfied = compare(transformed, value) > 0;
      break;
    case '>=':
      satisfied = compare(transformed, value) >= 0;
      break;
    case '<':
      satisfied = compare(transformed, value) < 0;
      break;
    case '<=':
      satisfied = compare(transformed, value) <= 0;
      break;
    case 'between':
      satisfied = compare(transformed, value) >= 0 && compare(transformed, value2) <= 0;
      break;
    case 'contains':
      satisfied = String(transformed).toLowerCase().includes(String(value ?? '').toLowerCase());
      break;
    case 'startsWith':
      satisfied = String(transformed).toLowerCase().startsWith(String(value ?? '').toLowerCase());
      break;
    case 'endsWith':
      satisfied = String(transformed).toLowerCase().endsWith(String(value ?? '').toLowerCase());
      break;
    case 'truthy':
      satisfied = Boolean(transformed) && transformed !== '0';
      break;
    default:
      return {
        id: predicate.id || '',
        label,
        expression,
        satisfied: false,
        evaluable: false,
        reason: `unsupported operator "${op}"`
      };
  }
  return {
    id: predicate.id || '',
    label,
    expression,
    satisfied,
    evaluable: true
  };
}

function buildExpression(predicate) {
  const tx = predicate.transform || 'identity';
  const lhs = tx === 'identity' || tx === '' ? predicate.sourcePath : `${tx}(${predicate.sourcePath})`;
  if (predicate.op === 'between') {
    return `${lhs} in [${predicate.value}, ${predicate.value2}]`;
  }
  if (predicate.op === 'truthy') {
    return `${lhs} is truthy`;
  }
  return `${lhs} ${predicate.op} ${predicate.value}`;
}

export function isSelectionValid(selection) {
  if (!selection || typeof selection !== 'object') return false;
  const fields = Array.isArray(selection.fields) ? selection.fields : [];
  const predicates = Array.isArray(selection.predicates) ? selection.predicates : [];
  return fields.length + predicates.length > 0;
}

// Older mobile builds stored labels produced by a buggy `replaceAll` that
// substituted the literal template `$1 $2` instead of expanding capture
// groups (e.g. `Use$1 $2oi$1 $2ate` for `userJoinDate`). The original
// camelCase boundaries are lost in those labels, so we re-derive a clean
// human label from the still-intact `path` whenever a stored label looks
// corrupted or was never customised.
function prettifyPath(rawPath) {
  let cleaned = String(rawPath || '').trim();
  if (cleaned.startsWith('$.')) cleaned = cleaned.slice(2);
  else if (cleaned.startsWith('$')) cleaned = cleaned.slice(1);
  const parts = cleaned.split('.').filter(Boolean);
  const source = parts.length ? parts[parts.length - 1] : cleaned;
  return source
    .replace(/[^a-zA-Z0-9]+/g, ' ')
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .split(' ')
    .filter(Boolean)
    .map((word) => word[0].toUpperCase() + word.slice(1))
    .join(' ');
}

function chooseLabel(rawLabel, path) {
  const candidate = String(rawLabel ?? '').trim();
  const fromPath = prettifyPath(path);
  if (!candidate) return fromPath || path;
  if (/\$\d/.test(candidate)) return fromPath || path;
  if (candidate === path) return fromPath || path;
  return candidate;
}

export function evaluateSelection(selection, artifactOrRevealed) {
  const revealed = resolveRevealedBody(artifactOrRevealed);
  const fieldList = Array.isArray(selection?.fields) ? selection.fields : [];
  const fields = {};
  for (const field of fieldList) {
    if (!field || typeof field !== 'object') continue;
    const path = String(field.path || '');
    if (!path) continue;
    const label = chooseLabel(field.label, path);
    fields[label] = lookupValue(revealed, path) ?? null;
  }
  const predicateList = Array.isArray(selection?.predicates) ? selection.predicates : [];
  const predicates = predicateList
    .filter((predicate) => predicate && typeof predicate === 'object')
    .map((predicate) => evaluatePredicate(predicate, revealed));
  return { fields, predicates };
}
