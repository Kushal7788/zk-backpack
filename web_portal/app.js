const { createApp, computed, ref } = window.Vue;

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

createApp({
  setup() {
    const initialToken =
      window.__SHARE_TOKEN__ && window.__SHARE_TOKEN__ !== '__SHARE_TOKEN__'
        ? window.__SHARE_TOKEN__
        : '';
    const tokenInput = ref(initialToken);
    const loading = ref(false);
    const status = ref('pending');
    const message = ref('Paste a share URL/token or verify the preloaded token.');
    const verification = ref({});
    const claims = ref({});
    const receipt = ref({});

    const statusClass = computed(() => {
      if (loading.value) return 'status status-pending';
      if (status.value === 'valid') return 'status status-valid';
      if (status.value === 'pending') return 'status status-pending';
      return 'status status-blocked';
    });

    const canCopyReceipt = computed(() => Boolean(receipt.value.signature));

    async function verifyNow() {
      const token = parseToken(tokenInput.value);
      if (!token) {
        status.value = 'invalid';
        message.value = 'Enter a valid token or share URL.';
        verification.value = {};
        claims.value = {};
        receipt.value = {};
        return;
      }
      loading.value = true;
      status.value = 'pending';
      message.value = 'Resolving and verifying credential...';
      verification.value = {};
      claims.value = {};
      receipt.value = {};
      try {
        const response = await fetch(
          `/api/share/view?token=${encodeURIComponent(token)}`
        );
        const payload = await response.json().catch(() => ({}));
        status.value = payload.status ?? (response.ok ? 'valid' : 'invalid');
        message.value = payload.message ?? 'No message returned';
        verification.value = payload.verification ?? {};
        claims.value = payload.scopedClaims ?? {};
        receipt.value = payload.receipt ?? {};
      } catch (error) {
        status.value = 'invalid';
        message.value = error instanceof Error ? error.message : String(error);
      } finally {
        loading.value = false;
      }
    }

    async function copyReceipt() {
      if (!canCopyReceipt.value) return;
      const raw = JSON.stringify(receipt.value, null, 2);
      await navigator.clipboard.writeText(raw);
    }

    if (initialToken) {
      verifyNow();
    }

    return {
      tokenInput,
      loading,
      status,
      message,
      verification,
      claims,
      receipt,
      statusClass,
      canCopyReceipt,
      verifyNow,
      copyReceipt
    };
  },
  template: `
    <main class="container">
      <section class="card">
        <h1>ZK Backpack Verification Portal</h1>
        <p class="muted">
          Server-side verification is executed before any scoped credential data is shown.
        </p>

        <div class="token-row">
          <input
            v-model="tokenInput"
            class="token-input"
            placeholder="Paste share URL or token"
          />
          <button class="primary-btn" :disabled="loading" @click="verifyNow">
            {{ loading ? 'Verifying...' : 'Verify' }}
          </button>
        </div>

        <div :class="statusClass">
          {{ status.toUpperCase() }}: {{ message }}
        </div>

        <h2>Verification Summary</h2>
        <pre class="panel">{{ JSON.stringify(verification, null, 2) }}</pre>

        <h2>Scoped Claims</h2>
        <pre class="panel">{{ JSON.stringify(claims, null, 2) }}</pre>

        <div class="receipt-row">
          <h2>Verification Receipt</h2>
          <button class="secondary-btn" :disabled="!canCopyReceipt" @click="copyReceipt">
            Copy receipt
          </button>
        </div>
        <pre class="panel">{{ JSON.stringify(receipt, null, 2) }}</pre>
      </section>
    </main>
  `
}).mount('#app');
