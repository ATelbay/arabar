# Account limits review — 2026-09-30

Scope: AccountQuotaReader, GeminiOAuthClient, AccountQuotaSnapshot, AccountQuotaSettingsTab. Existing uncommitted account-limit implementation was preserved. No real credentials were read and no authenticated requests were made.

## Confirmed fixes

| ID | Severity | Trigger and root cause | Fix | Regression coverage |
| --- | --- | --- | --- | --- |
| AQ-01 | P2 | Concurrent Gemini refreshes encounter an expired token. Actor reentrancy at the OAuth request allowed every caller to exchange the same refresh token independently. | Share the pending refresh task for the same credential data. Remove completed/failed tasks by operation ID so a delayed waiter cannot erase a newer refresh. | `testConcurrentExpiredCredentialsShareOneRefresh` sends eight concurrent requests and requires exactly one OAuth exchange; `testFailedRefreshDoesNotPoisonFutureAttempts` checks recovery. |
| AQ-02 | P2 | An old-token 401 arrives after another request has refreshed successfully. The old handler cleared the new cache and refreshed again. | Pass the rejected token to token acquisition; reuse a valid cached token when it differs from the rejected one. | `testLateUnauthorizedResponseReusesAlreadyRefreshedToken` delays the second 401 until the first refresh completes and requires one exchange. |
| AQ-03 | P2 | Gemini CLI signs out or changes accounts during quota retrieval. Configuration equality does not include the CLI credential file, so the prior account's successful response could be published. | Read the file again before returning the snapshot; changed/unreadable credentials return a snapshot-invalidating `credentialsChanged` error. Credential loading is injected in tests. | `testLoginChangeDuringRequestDiscardsPreviousAccountsQuota`; unchanged-login success control. |
| AQ-04 | P2 | Gemini's credential file is malformed/incomplete. The generic JSON parser classified this as a transient provider response error, keeping the previous account snapshot and showing the wrong recovery message. | Classify malformed local credential JSON as `missingGeminiLogin`, which invalidates the snapshot. | `testMalformedLoginInvalidatesPreviousQuotaWithoutMakingRequests`. |
| AQ-05 | P3 | A replacement key is typed, then Clear key removes the saved key. The typed secret stayed in the SecureField and could immediately be saved again accidentally. | Clear the draft field after successful Keychain removal. | Direct action-path review; no new UI test for this one-line edit. |

Validation: `rtk swift test --filter AccountQuota` passed 19 tests (6 new, 13 existing). AQ-05 was applied after this run and needs the final shared build. Existing tests cover remaining-fraction parsing, malformed quota values, freshness/reset boundaries, endpoint/auth headers, OAuth form encoding, and installed CLI client discovery.

## Contract checks and limits

The current [official Gemini Code Assist types](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/types.ts) match the implemented project-string, HEALTH_CHECK and quota-bucket structures. [Official Gemini OAuth source](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/oauth2.ts) confirms the installed application's named client constants. [Kimi Code documentation](https://www.kimi.com/code/docs/en/) confirms the China/international host mapping.

Provider schemas were checked without using real accounts. Successful tests establish request/parser behavior against synthetic fixtures, not live subscription compatibility. CLI credential updates are compared byte-for-byte; even an access-token-only rewrite conservatively drops that in-flight response until the next refresh. A logout after a completed refresh is noticed on the next refresh; there is no filesystem watcher. Gemini client discovery depends on supported npm/Homebrew paths or the app's PATH.

Separate finding forwarded to the parent review: `KeychainStore.set` removed an existing key before an add operation could fail. The parent owns that shared Keychain fix and its tests.
