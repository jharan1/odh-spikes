# Implementation Plan: Enable External Vector Stores in Playground Knowledge Tab

Jira: https://issues.redhat.com/browse/RHOAIENG-51775

## Story Summary

As an AI Engineer, I want to see all external vector stores registered in llamastack in my namespace
listed in the Playground Knowledge tab, be able to enable or disable one for my chat session, and
have my selection carried over when I open additional comparison panes.

## Acceptance Criteria

- [ ] External vector stores registered/installed in the namespace llamastack are listed in the
      Playground Knowledge tab when the feature flag is enabled.
- [ ] Each store entry displays its name and description if provided.
- [ ] On open of the Knowledge tab, the user sees two radio options:
      - "Use uploaded documents" (tooltip: "Upload and use your own files as grounding knowledge.
        Files are chunked, embedded, and stored in a playground-local database.")
      - "Use an existing vector store" (tooltip: "Connect to a registered external vector store
        collection to provide the model with custom knowledge and context.")
- [ ] Selecting "Use uploaded documents" shows the existing "Drag and drop or upload files" section.
- [ ] Selecting "Use an existing vector store":
      - If no external vector stores are registered in llamastack: show "No collections configured"
        heading + "To use a vector store, go to AI asset endpoints and add a collection to the
        playground." message + "Go to AI asset endpoints" link.
      - If vector stores are registered: show a dropdown of vector store items with name and
        description.
- [ ] User can enable an external vector store with a single click; only one can be active per pane.
- [ ] User can disable the active vector store mid-session, reverting to non-RAG behaviour.
- [ ] The enabled vector store is stored in chat session state and used for retrieval on subsequent messages.
- [ ] When a new comparison pane is opened, the current vector store selection is replicated.
- [ ] After a pane is opened, its vector store selection is independent.
- [ ] Retrieval implementation details are not shown to the user.

---

## Architecture Overview

### Current State

- `KnowledgeTabContent.tsx` — RAG toggle (Switch) + file upload panel + uploaded files list.
- `useFetchVectorStores` — fetches vector stores from the LlamaStack `/v1/vector_stores` API
  (stores installed into the LSD instance).
- `useFetchAAEVectorStores` — fetches external vector stores from the BFF ConfigMap (AI Asset
  Endpoints); used for the AI Assets page, NOT for the playground tab.
- `useAiAssetVectorStoresEnabled` — reads feature flag `ai-asset-vector-stores`.
- `ChatbotConfiguration` (Zustand store) — holds `isRagEnabled: boolean` per pane.
- `ChatbotConfigInstance.tsx` — reads `isRagEnabled` from store, passes `currentVectorStoreId`
  (from `fileManagement.currentVectorStoreId`) to `useChatbotMessages`.
- `useChatbotMessages` — uses `vector_store_ids: [currentVectorStoreId]` in the API payload when
  `isRawUploaded` (i.e. `isRagEnabled`) is true.

### Data Source Clarification

The Knowledge tab should use **`useFetchVectorStores`** (LlamaStack API), NOT `useFetchAAEVectorStores`
(BFF ConfigMap). The AC specifies "external vector stores registered/installed in the namespace
llamastack" — i.e. stores that are actually live in the LSD instance and ready to query.

---

## Implementation Plan

### Phase 1: Store changes

#### `store/types.ts`

Add to `ChatbotConfiguration`:
```ts
/** Which knowledge source mode is selected for this pane */
knowledgeMode: 'upload' | 'external';
/** The external vector store ID selected for RAG in this pane (external mode only) */
selectedExternalVectorStoreId: string | null;
```

Update `DEFAULT_CONFIGURATION`:
```ts
knowledgeMode: 'upload',
selectedExternalVectorStoreId: null,
```

Add to `ChatbotConfigStoreActions`:
```ts
updateKnowledgeMode: (id: string, value: 'upload' | 'external') => void;
updateSelectedExternalVectorStoreId: (id: string, value: string | null) => void;
```

#### `store/useChatbotConfigStore.ts`

Implement the two new action methods (same pattern as `updateRagEnabled`).

Update `duplicateConfiguration` to copy the new fields:
```ts
const newConfig: ChatbotConfiguration = {
  ...
  knowledgeMode: sourceConfig.knowledgeMode,
  selectedExternalVectorStoreId: sourceConfig.selectedExternalVectorStoreId,
};
```

This fulfills the AC: "When a new comparison pane is opened, the current vector store selection
is replicated to it by default."

#### `store/selectors.ts`

Add:
```ts
export const selectKnowledgeMode =
  (configId: string) =>
  (state: ChatbotConfigStore): 'upload' | 'external' =>
    state.configurations[configId]?.knowledgeMode ?? DEFAULT_CONFIGURATION.knowledgeMode;

export const selectSelectedExternalVectorStoreId =
  (configId: string) =>
  (state: ChatbotConfigStore): string | null =>
    state.configurations[configId]?.selectedExternalVectorStoreId ??
    DEFAULT_CONFIGURATION.selectedExternalVectorStoreId;
```

---

### Phase 2: KnowledgeTabContent UI

**File:** `app/Chatbot/components/settingsPanelTabs/KnowledgeTabContent.tsx`

#### When feature flag is OFF

Render the existing UI unchanged (no radio buttons, existing toggle + upload).

#### When feature flag is ON

Replace the existing Switch toggle + Form with:

1. Two `Radio` components (PatternFly):
   - **"Use uploaded documents"** with a Popover/tooltip on the label
   - **"Use an existing vector store"** with a Popover/tooltip on the label

2. Content below the radios changes based on `knowledgeMode` from the Zustand store:

**mode = 'upload'** (Radio 1 selected):
- Render the existing `ChatbotSourceUploadPanel` + `UploadedFilesList` (unchanged)

**mode = 'external'** (Radio 2 selected):
- Call `useFetchVectorStores()` to get installed LlamaStack vector stores
- **Loading state**: spinner / skeleton
- **Empty state** (`vectorStores.length === 0`):
  - Heading: "No collections configured"
  - Body: "To use a vector store, go to AI asset endpoints and add a collection to the playground."
  - Link button: "Go to AI asset endpoints" → `genAiAiAssetsRoute(namespace)`
- **Populated state**: PatternFly `Select` dropdown
  - Each option shows `store.name` + `store.metadata?.description` if present
  - Selecting an option:
    - `updateSelectedExternalVectorStoreId(configId, store.id)`
    - `updateRagEnabled(configId, true)`
  - Clearing the selection:
    - `updateSelectedExternalVectorStoreId(configId, null)`
    - `updateRagEnabled(configId, false)`

The existing top-level RAG `Switch` is removed when flag is ON (enabling/disabling RAG is now
implicit via radio selection and dropdown choice).

The `KnowledgeTabContent` needs `namespace` passed as a new prop (for the "Go to AI asset
endpoints" link). It is already available in `ChatbotPlayground` via the `namespace` hook.

---

### Phase 3: ChatbotConfigInstance — effective RAG state

**File:** `app/Chatbot/ChatbotConfigInstance.tsx`

Read the new store fields:
```ts
const knowledgeMode = useChatbotConfigStore(selectKnowledgeMode(configId));
const selectedExternalVectorStoreId = useChatbotConfigStore(
  selectSelectedExternalVectorStoreId(configId),
);
```

Compute effective values before passing to `useChatbotMessages`:
```ts
// Upload mode: use the uploaded-files vector store; external mode: use the selected store
const effectiveVectorStoreId =
  knowledgeMode === 'external' ? selectedExternalVectorStoreId : currentVectorStoreId;

// Upload mode: controlled by the isRagEnabled toggle; external mode: true when a store is selected
const effectiveIsRagEnabled =
  knowledgeMode === 'external' ? Boolean(selectedExternalVectorStoreId) : isRagEnabled;
```

Pass these to `useChatbotMessages`:
```ts
isRawUploaded: effectiveIsRagEnabled,
currentVectorStoreId: effectiveVectorStoreId,
```

No changes needed to `useChatbotMessages` itself.

---

### Phase 4: ChatbotSettingsPanel / ChatbotPlayground wiring

**`ChatbotSettingsPanel.tsx`**: Pass `namespace` down to `KnowledgeTabContent`.

**`ChatbotPlayground.tsx`**: Already has `namespace` in scope; pass it through to the settings panel.

---

### Phase 5: Tests

#### `KnowledgeTabContent.spec.tsx`

Mock `useAiAssetVectorStoresEnabled` and `useFetchVectorStores`.

New test cases:
- When flag OFF: existing upload-only UI renders (existing tests still pass)
- When flag ON, mode = 'upload': radio 1 checked, upload panel shown, radio 2 not checked
- When flag ON, mode = 'external', loading: spinner visible
- When flag ON, mode = 'external', no stores: empty state rendered with link
- When flag ON, mode = 'external', stores present: dropdown rendered with store options
- Selecting a store from dropdown: updates `selectedExternalVectorStoreId` + enables RAG in store
- Clicking "Use uploaded documents" radio: calls `updateKnowledgeMode(configId, 'upload')`
- Clicking "Use an existing vector store" radio: calls `updateKnowledgeMode(configId, 'external')`

#### `store/__tests__/useChatbotConfigStore.test.ts`

- `updateKnowledgeMode` sets the correct value
- `updateSelectedExternalVectorStoreId` sets the correct value
- `duplicateConfiguration` copies `knowledgeMode` and `selectedExternalVectorStoreId`
- `resetConfiguration` resets both to defaults

---

## Files to Modify

| File | Type of change |
|---|---|
| `store/types.ts` | Add 2 fields to config type + 2 action signatures |
| `store/useChatbotConfigStore.ts` | Implement 2 new actions, update `duplicateConfiguration` |
| `store/selectors.ts` | Add 2 new selectors |
| `KnowledgeTabContent.tsx` | Full rework with flag-gated radio buttons + external store UI |
| `ChatbotConfigInstance.tsx` | Compute effective vector store ID + RAG enabled from mode |
| `ChatbotSettingsPanel.tsx` | Pass `namespace` prop down to `KnowledgeTabContent` |
| `ChatbotPlayground.tsx` | Pass `namespace` through to `ChatbotSettingsPanel` |
| `KnowledgeTabContent.spec.tsx` | Update + extend tests |
| `store/__tests__/useChatbotConfigStore.test.ts` | Test new store actions |

No new files required.

---

## Key Decisions

1. **Data source**: Use `useFetchVectorStores` (LlamaStack API) not `useFetchAAEVectorStores`
   (BFF ConfigMap). The AC asks for stores "registered/installed in llamastack".

2. **RAG toggle removal**: When the feature flag is ON, the top-level Switch toggle is replaced
   by the radio + dropdown flow. This avoids double-toggle confusion.

3. **Effective RAG state computed in ChatbotConfigInstance**: `useChatbotMessages` is unchanged;
   the caller computes the effective vector store ID and RAG enabled flag before passing them in.

4. **Pane independence after duplication**: `duplicateConfiguration` copies the selection so the
   new pane starts with the same state, but each pane's store slice is independent after that.
