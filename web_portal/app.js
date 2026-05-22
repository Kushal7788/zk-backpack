const { createApp, computed, ref } = window.Vue;

const SHARE_SERVICE_BASE = (() => {
  const raw = window.__SHARE_SERVICE_BASE__;
  if (!raw || raw === '%%SHARE_SERVICE_BASE%%') return '';
  return raw.replace(/\/+$/, '');
})();

function apiUrl(path) {
  return `${SHARE_SERVICE_BASE}${path}`;
}

function parseToken(raw) {
  const input = (raw ?? '').trim();
  if (!input) return '';
  try {
    const asUrl = new URL(input, window.location.origin);
    const segments = asUrl.pathname.split('/').filter(Boolean);
    return segments.length ? segments[segments.length - 1] : input;
  } catch {
    return input;
  }
}

function prettifyKey(key) {
  let cleaned = String(key ?? '').trim();
  // Defensive cleanup for share records produced by an older app build
  // that stored the literal "$1 $2" replacement template instead of the
  // expanded back-reference. Strip the leftover token so legacy labels
  // still render readably.
  cleaned = cleaned.replace(/\$1\s*\$2/g, '');
  if (cleaned.startsWith('$.')) cleaned = cleaned.slice(2);
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

const ISO_DATE_RE =
  /^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?(Z|[+-]\d{2}:?\d{2})?)?$/;

function humanizeDateLike(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!ISO_DATE_RE.test(trimmed)) return null;
  const date = new Date(trimmed);
  if (Number.isNaN(date.getTime())) return null;
  try {
    const dateOnly = !trimmed.includes('T');
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: 'medium',
      ...(dateOnly ? {} : { timeStyle: 'short' })
    }).format(date);
  } catch {
    return date.toISOString();
  }
}

function printable(value) {
  if (value == null) return '';
  if (typeof value === 'string') {
    const humanDate = humanizeDateLike(value);
    return humanDate ?? value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return JSON.stringify(value);
}

function providerDomain(value) {
  let source = String(value ?? '').trim();
  if (!source) return '';
  source = source.replace(/^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+/i, '');
  try {
    const parsed = new URL(source.includes('://') ? source : `https://${source}`);
    return parsed.hostname.toLowerCase();
  } catch {
    return source.split('/')[0].split('?')[0].split('#')[0].toLowerCase();
  }
}

function humanDate(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  try {
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: 'medium',
      timeStyle: 'short'
    }).format(date);
  } catch {
    return date.toISOString();
  }
}

function shortHash(value) {
  const raw = String(value ?? '').trim();
  if (!raw) return '';
  return raw.length <= 16 ? raw : `${raw.slice(0, 10)}...${raw.slice(-6)}`;
}

function formatDurationUntil(iso) {
  if (!iso) return '';
  const expires = new Date(iso);
  if (Number.isNaN(expires.getTime())) return humanDate(iso);
  const diffMs = expires.getTime() - Date.now();
  if (diffMs <= 0) return 'Expired';
  const minutes = Math.ceil(diffMs / 60000);
  if (minutes < 90) return `${minutes} minute${minutes === 1 ? '' : 's'}`;
  const hours = Math.ceil(minutes / 60);
  if (hours < 36) return `${hours} hour${hours === 1 ? '' : 's'}`;
  const days = Math.ceil(hours / 24);
  return `${days} day${days === 1 ? '' : 's'}`;
}

// Inline SVG strings.
const ICON_CHECK =
  '<svg class="status-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><polyline points="8 12.5 11 15.5 16.5 9.5"/></svg>';
const ICON_CROSS =
  '<svg class="status-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><line x1="9" y1="9" x2="15" y2="15"/><line x1="15" y1="9" x2="9" y2="15"/></svg>';
const ICON_DASH =
  '<svg class="status-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"/><line x1="8" y1="12" x2="16" y2="12"/></svg>';
const ICON_PRED_CHECK =
  '<svg class="predicate-icon predicate-icon-true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="5 12.5 10 17.5 19 7.5"/></svg>';
const ICON_PRED_CROSS =
  '<svg class="predicate-icon predicate-icon-false" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="6" y1="6" x2="18" y2="18"/><line x1="18" y1="6" x2="6" y2="18"/></svg>';
const ICON_PRED_DASH =
  '<svg class="predicate-icon predicate-icon-unknown" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="5" y1="12" x2="19" y2="12"/></svg>';
const ICON_CHEVRON =
  '<svg class="chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="9 6 15 12 9 18"/></svg>';

createApp({
  setup() {
    const presetToken =
      window.__SHARE_TOKEN__ &&
      window.__SHARE_TOKEN__ !== '%%SHARE_TOKEN_VALUE%%'
        ? window.__SHARE_TOKEN__
        : '';

    // Phases: 'idle' (no token), 'loading', 'resolved'.
    const phase = ref(presetToken ? 'loading' : 'idle');
    const tokenInput = ref(presetToken);
    const inputVisible = ref(!presetToken);

    const status = ref('pending');
    const message = ref('Paste a share link or token to view a proof.');
    const verification = ref({});
    const claims = ref({});
    const receipt = ref({});
    const share = ref({});
    const verifiedAt = ref('');
    const targetHost = ref('');

    const receiptVerification = ref(null);
    const receiptVerifyBusy = ref(false);
    const copyState = ref({});

    const statusKind = computed(() => {
      if (phase.value === 'idle') return 'pending';
      if (phase.value === 'loading') return 'loading';
      const s = String(status.value || '').toLowerCase();
      if (s === 'valid') return 'valid';
      if (s === 'pending' || s === 'unknown') return 'warn';
      return 'danger';
    });

    const statusWord = computed(() => {
      const kind = statusKind.value;
      if (kind === 'pending') return 'Waiting';
      if (kind === 'loading') return 'Verifying';
      if (kind === 'valid') return 'Verified';
      if (kind === 'warn') return 'Inconclusive';
      const s = String(status.value || '').toLowerCase();
      if (s === 'expired') return 'Expired';
      if (s === 'revoked') return 'Revoked';
      if (s === 'consumed') return 'Already used';
      if (s === 'max_views_reached') return 'View limit reached';
      return 'Not valid';
    });

    const statusCopy = computed(() => {
      const kind = statusKind.value;
      if (kind === 'pending') return 'Paste a share link or token to view a proof.';
      if (kind === 'loading') return 'Checking signatures and policy.';
      if (kind === 'valid') {
        const host = targetHost.value;
        return host
          ? `This proof was verified against ${host}.`
          : 'This proof is valid.';
      }
      const detail = (message.value || '').trim();
      if (kind === 'warn') {
        return detail || 'This proof could not be fully evaluated.';
      }
      return detail
        ? `Do not rely on this proof. ${detail}`
        : 'Do not rely on this proof.';
    });

    const statusIcon = computed(() => {
      const kind = statusKind.value;
      if (kind === 'valid') return ICON_CHECK;
      if (kind === 'warn' || kind === 'loading' || kind === 'pending') return ICON_DASH;
      return ICON_CROSS;
    });

    const fields = computed(() => {
      const value = claims.value || {};
      const fromShape = value.fields;
      if (fromShape && typeof fromShape === 'object' && !Array.isArray(fromShape)) {
        return Object.entries(fromShape).map(([label, raw]) => ({
          label: prettifyKey(label),
          value: printable(raw)
        }));
      }
      if (Array.isArray(value.predicates) || 'fields' in value) {
        return [];
      }
      // Legacy flat shape.
      return Object.entries(value).map(([label, raw]) => ({
        label: prettifyKey(label),
        value: printable(raw)
      }));
    });

    const predicates = computed(() => {
      const value = claims.value || {};
      if (!Array.isArray(value.predicates)) return [];
      return value.predicates.map((predicate) => {
        const evaluable = predicate.evaluable !== false;
        const satisfied = predicate.satisfied === true;
        let outcome;
        let icon;
        let kind;
        if (!evaluable) {
          outcome = 'Inconclusive';
          icon = ICON_PRED_DASH;
          kind = 'unknown';
        } else if (satisfied) {
          outcome = 'Verified';
          icon = ICON_PRED_CHECK;
          kind = 'true';
        } else {
          outcome = 'Not met';
          icon = ICON_PRED_CROSS;
          kind = 'false';
        }
        return {
          id: predicate.id || predicate.label,
          label: predicate.label || 'Condition',
          expression: predicate.expression || '',
          reason: predicate.reason || '',
          evaluable,
          satisfied,
          outcome,
          icon,
          kind
        };
      });
    });

    const trustPanelVisible = computed(
      () => phase.value === 'resolved' && statusKind.value === 'valid'
    );

    const satisfiedPredicateCount = computed(
      () => predicates.value.filter((predicate) => predicate.satisfied).length
    );

    const conditionSummary = computed(() => {
      const total = predicates.value.length;
      if (!total) return 'No conditions requested';
      const satisfied = satisfiedPredicateCount.value;
      return `${satisfied}/${total} condition${total === 1 ? '' : 's'} met`;
    });

    const revealedSummary = computed(() => {
      const fieldCount = fields.value.length;
      const conditionCount = predicates.value.length;
      if (!fieldCount && !conditionCount) return 'No claims released';
      const parts = [];
      if (fieldCount) {
        parts.push(`${fieldCount} field${fieldCount === 1 ? '' : 's'}`);
      }
      if (conditionCount) {
        parts.push(`${conditionCount} condition${conditionCount === 1 ? '' : 's'}`);
      }
      return `${parts.join(' + ')} released`;
    });

    const sharePolicySummary = computed(() => {
      const current = share.value || {};
      const parts = [];
      if (current.oneTimeView) parts.push('One-time link');
      if (current.maxViews != null) {
        const max = Number(current.maxViews);
        if (Number.isFinite(max)) {
          parts.push(`Up to ${max} view${max === 1 ? '' : 's'}`);
        }
      }
      if (current.expiresAtUtc) {
        const duration = formatDurationUntil(current.expiresAtUtc);
        parts.push(
          duration === 'Expired'
            ? 'Expired'
            : `Expires in ${duration}`
        );
      }
      if (parts.length) return parts.join(' · ');
      return 'Share policy active';
    });

    const trustRows = computed(() => {
      const rows = [
        {
          label: 'Verification',
          value: 'Server-verified TLSNotary proof'
        },
        {
          label: 'Released',
          value: revealedSummary.value
        },
        {
          label: 'Conditions',
          value: conditionSummary.value
        },
        {
          label: 'Policy',
          value: sharePolicySummary.value
        }
      ];
      if (targetHost.value) {
        rows.splice(1, 0, {
          label: 'Source',
          value: targetHost.value
        });
      }
      if (verifiedAt.value) {
        rows.push({
          label: 'Verified at',
          value: humanDate(verifiedAt.value)
        });
      }
      const hash = receipt.value && receipt.value.artifactHash;
      if (hash) {
        rows.push({
          label: 'Artifact hash',
          value: shortHash(hash)
        });
      }
      return rows;
    });

    const metaLine = computed(() => {
      const at = verifiedAt.value;
      const host = targetHost.value;
      if (!at && !host) return '';
      const parts = [];
      if (at) parts.push(`Verified ${humanDate(at)}`);
      if (host) parts.push(host);
      return parts.join(' · ');
    });

    const verificationJson = computed(() =>
      JSON.stringify(verification.value || {}, null, 2)
    );
    const receiptJson = computed(() => JSON.stringify(receipt.value || {}, null, 2));

    const canVerify = computed(() => Boolean(tokenInput.value && tokenInput.value.trim()));

    async function verifyNow() {
      const token = parseToken(tokenInput.value);
      if (!token) {
        phase.value = 'idle';
        status.value = 'invalid';
        message.value = 'Enter a valid token or share URL.';
        verification.value = {};
        claims.value = {};
        receipt.value = {};
        share.value = {};
        verifiedAt.value = '';
        targetHost.value = '';
        receiptVerification.value = null;
        return;
      }
      phase.value = 'loading';
      status.value = 'pending';
      message.value = 'Checking signatures and policy.';
      verification.value = {};
      claims.value = {};
      receipt.value = {};
      share.value = {};
      verifiedAt.value = '';
      targetHost.value = '';
      receiptVerification.value = null;
      try {
        const response = await fetch(
          apiUrl(`/api/share/view?token=${encodeURIComponent(token)}`)
        );
        const payload = await response.json().catch(() => ({}));
        status.value = payload.status ?? (response.ok ? 'valid' : 'invalid');
        message.value = payload.message ?? '';
        verification.value = payload.verification ?? {};
        claims.value = payload.scopedClaims ?? {};
        receipt.value = payload.receipt ?? {};
        share.value = payload.share ?? {};
        verifiedAt.value =
          (payload.receipt && payload.receipt.verifiedAt) || '';
        // Best-effort source domain extraction.
        const fromReceipt =
          payload.receipt && payload.receipt.sourceDomain
            ? payload.receipt.sourceDomain
            : null;
        targetHost.value =
          providerDomain(payload.share && payload.share.sourceDomain) ||
          providerDomain(fromReceipt) ||
          extractHost(payload) ||
          '';
      } catch (error) {
        status.value = 'invalid';
        message.value = error instanceof Error ? error.message : String(error);
      } finally {
        phase.value = 'resolved';
      }
    }

    function extractHost(payload) {
      const v = payload && payload.verification;
      if (v && typeof v === 'object') {
        if (typeof v.targetHost === 'string') return providerDomain(v.targetHost);
        if (typeof v.host === 'string') return providerDomain(v.host);
      }
      return '';
    }

    async function copyBlock(name, text) {
      try {
        await navigator.clipboard.writeText(text);
        copyState.value = { ...copyState.value, [name]: true };
        setTimeout(() => {
          copyState.value = { ...copyState.value, [name]: false };
        }, 1200);
      } catch {
        // Clipboard may be unavailable; silently ignore.
      }
    }

    async function verifyReceiptSignature() {
      if (!receipt.value.signature) return;
      receiptVerifyBusy.value = true;
      receiptVerification.value = null;
      try {
        const response = await fetch(apiUrl('/api/share/receipt/verify'), {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ signature: receipt.value.signature })
        });
        const body = await response.json().catch(() => ({}));
        receiptVerification.value = {
          ok: body.ok === true,
          message:
            body.message || (body.ok ? 'Signature verified' : 'Invalid signature')
        };
      } catch (error) {
        receiptVerification.value = {
          ok: false,
          message: error instanceof Error ? error.message : String(error)
        };
      } finally {
        receiptVerifyBusy.value = false;
      }
    }

    function toggleInput() {
      inputVisible.value = !inputVisible.value;
    }

    if (presetToken) {
      verifyNow();
    }

    return {
      // state
      phase,
      tokenInput,
      inputVisible,
      receipt,
      share,
      receiptVerification,
      receiptVerifyBusy,
      copyState,
      // derived
      statusKind,
      statusWord,
      statusCopy,
      statusIcon,
      fields,
      predicates,
      trustPanelVisible,
      trustRows,
      metaLine,
      verificationJson,
      receiptJson,
      canVerify,
      // actions
      verifyNow,
      copyBlock,
      verifyReceiptSignature,
      toggleInput,
      // icons
      ICON_CHEVRON
    };
  },
  template: `
    <main class="page">
      <header class="portal-header">
        <div class="portal-mark" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
            <path d="M6 8a3 3 0 0 1 3-3h6a3 3 0 0 1 3 3v10a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V8Z" />
            <path d="M9 5V4a3 3 0 0 1 6 0v1" />
            <path d="M9 12h6" />
          </svg>
        </div>
        <div class="portal-title">
          <div class="portal-name">ZK Backpack</div>
          <div class="portal-sub">Credential viewer</div>
        </div>
      </header>
      <section
        class="card status"
        :class="['status-' + statusKind, statusKind === 'pending' ? 'status-pending-card' : '']"
      >
        <div class="status-row">
          <span v-html="statusIcon" class="status-icon-wrap"></span>
          <span class="status-word">{{ statusWord }}</span>
        </div>
        <div class="status-copy">{{ statusCopy }}</div>

        <form
          v-if="inputVisible || phase === 'idle'"
          class="token-form"
          @submit.prevent="verifyNow"
        >
          <input
            v-model="tokenInput"
            class="token-input"
            placeholder="Paste a share URL or token"
            aria-label="Share URL or token"
            autocomplete="off"
            spellcheck="false"
          />
          <button class="token-button" :disabled="!canVerify || phase === 'loading'" type="submit">
            {{ phase === 'loading' ? 'Verifying…' : 'Verify' }}
          </button>
        </form>
      </section>

      <section class="card trust-panel" v-if="trustPanelVisible">
        <div class="section-label">Verification summary</div>
        <div class="trust-head">
          <div>
            <div class="trust-title">Verified proof</div>
            <div class="trust-subtitle">Only selected claims were released.</div>
          </div>
          <span class="trust-badge">Receipt available</span>
        </div>
        <div class="trust-grid">
          <div v-for="row in trustRows" :key="row.label" class="trust-row">
            <div class="trust-label">{{ row.label }}</div>
            <div class="trust-value">{{ row.value }}</div>
          </div>
        </div>
      </section>

      <section class="card" v-if="phase !== 'idle'">
        <div class="section-label">Revealed information</div>

        <template v-if="phase === 'loading'">
          <div class="skeleton skeleton-60"></div>
          <div class="skeleton skeleton-80"></div>
          <div class="skeleton skeleton-40"></div>
        </template>

        <template v-else>
          <template v-if="fields.length">
            <div v-for="entry in fields" :key="entry.label" class="field-row">
              <div class="field-label">{{ entry.label }}</div>
              <div class="field-value">{{ entry.value }}</div>
            </div>
          </template>
          <div v-else class="field-empty">
            This proof reveals no fields — only the conditions below.
          </div>
        </template>
      </section>

      <section class="card" v-if="phase === 'resolved' && predicates.length">
        <div class="section-label">Conditions</div>
        <div
          v-for="predicate in predicates"
          :key="predicate.id"
          class="predicate-row"
        >
          <span v-html="predicate.icon"></span>
          <div class="predicate-body">
            <div class="predicate-label">{{ predicate.label }}</div>
            <div
              v-if="!predicate.evaluable && predicate.reason"
              class="predicate-reason"
            >
              {{ predicate.reason }}
            </div>
            <div
              v-else-if="!predicate.satisfied && predicate.evaluable && predicate.expression"
              class="predicate-reason"
            >
              {{ predicate.expression }}
            </div>
          </div>
          <div class="predicate-outcome">{{ predicate.outcome }}</div>
        </div>
      </section>

      <div v-if="phase === 'resolved' && metaLine" class="meta-line">
        {{ metaLine }}
      </div>

      <details v-if="phase === 'resolved'">
        <summary>
          <span v-html="ICON_CHEVRON"></span>
          View raw data
        </summary>

        <div class="raw-block">
          <div class="raw-block-head">
            <span>Verification</span>
            <button class="copy-btn" @click="copyBlock('verification', verificationJson)">
              {{ copyState.verification ? 'Copied' : 'Copy' }}
            </button>
          </div>
          <pre class="raw-pre">{{ verificationJson }}</pre>
        </div>

        <div class="raw-block">
          <div class="raw-block-head">
            <span>Receipt</span>
            <button class="copy-btn" @click="copyBlock('receipt', receiptJson)">
              {{ copyState.receipt ? 'Copied' : 'Copy' }}
            </button>
          </div>
          <pre class="raw-pre">{{ receiptJson }}</pre>

          <div class="raw-actions" v-if="receipt.signature">
            <button
              class="link-btn"
              :disabled="receiptVerifyBusy"
              @click="verifyReceiptSignature"
            >
              {{ receiptVerifyBusy ? 'Verifying…' : 'Verify signature' }}
            </button>
            <span
              v-if="receiptVerification"
              class="sig-pill"
              :class="receiptVerification.ok ? 'sig-pill-ok' : 'sig-pill-bad'"
            >
              {{ receiptVerification.ok ? 'Signature OK' : 'Signature invalid' }}
              · {{ receiptVerification.message }}
            </span>
          </div>
        </div>
      </details>

      <footer class="footer">
        <div>ZK Backpack</div>
        <button
          v-if="phase === 'resolved'"
          class="link-btn"
          type="button"
          @click="toggleInput"
        >
          {{ inputVisible ? 'Hide token input' : 'Verify another proof' }}
        </button>
      </footer>
    </main>
  `
}).mount('#app');
