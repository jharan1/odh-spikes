# Frontend Changes — External Vector Store Playground Support

Branch: `RHOAIENG-51775-enable-external-vector-stores-in-playground`

## Summary of Changes

### `ChatbotConfigInstance.tsx`

- Added `updateSelectedVectorStoreId` from store
- Added `useEffect` to sync the inline `currentVectorStoreId` prop into
  `selectedVectorStoreId` in the store when `knowledgeMode === 'inline'`
- Simplified `useChatbotMessages` call: `currentVectorStoreId: selectedVectorStoreId`
  (the store field now holds either the inline or external store ID)
- `isRawUploaded: isRagEnabled` directly (no `effectiveIsRagEnabled` indirection)

```tsx
// Sync inline store ID into unified selectedVectorStoreId
React.useEffect(() => {
  if (knowledgeMode === 'inline') {
    updateSelectedVectorStoreId(configId, currentVectorStoreId);
  }
}, [knowledgeMode, currentVectorStoreId, configId, updateSelectedVectorStoreId]);
```

### `KnowledgeTabContent.tsx` (feature-flag ON path)

- Added the RAG toggle (`<Switch>`) as `headerActions` in the flag-ON path,
  matching the flag-OFF path — `isRagEnabled` is now the master control for
  both inline and external modes
- Removed `updateRagEnabled(configId, true)` auto-call from the external store
  `onSelect` handler (the toggle is now the only way to enable/disable RAG)

### Store (`types.ts`, `useChatbotConfigStore.ts`, `selectors.ts`)

No new fields were added in this session. The existing fields added in the
prior session cover the new behaviour:

| Field                  | Type                  | Purpose                                     |
|------------------------|-----------------------|---------------------------------------------|
| `knowledgeMode`        | `'inline' \| 'external'` | Which knowledge source radio is selected |
| `selectedVectorStoreId`| `string \| null`      | Active vector store (inline or external)    |
| `isRagEnabled`         | `boolean`             | Master RAG toggle for both modes            |

## Key Design Decisions

1. **Unified `selectedVectorStoreId`**: rather than separate props for inline
   vs external store IDs, the store field holds whichever is active. In inline
   mode, a `useEffect` syncs the prop value in; in external mode, the dropdown
   sets it directly.

2. **`isRagEnabled` as master toggle**: the toggle is shown in both inline and
   external Knowledge tab views. Setting it to off suppresses RAG regardless of
   mode or store selection. This avoids silent auto-enabling of RAG when a user
   selects an external store.

3. **No `Boolean(selectedVectorStoreId)` shortcut**: downstream code handles
   `null` gracefully, so there's no need to coerce the toggle based on store
   presence.
