export async function verifyArtifact(verifierUrl, artifact) {
  const response = await fetch(`${verifierUrl}/v1/artifacts/verify`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json'
    },
    body: JSON.stringify({ artifact })
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    return {
      ok: false,
      integrityVerified: false,
      semanticVerified: false,
      reason: data.message ?? `Verifier HTTP ${response.status}`
    };
  }
  return {
    ok: Boolean(data.integrityVerified && data.semanticVerified),
    integrityVerified: Boolean(data.integrityVerified),
    semanticVerified: Boolean(data.semanticVerified),
    reason: data.reason ?? null
  };
}
