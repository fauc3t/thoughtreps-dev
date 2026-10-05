import { useMutation, useQueryClient } from '@tanstack/react-query';
import { deleteMessage } from '../api';
import { useSession } from '../session';

// Unlike useReply, address is a hook param (not a mutate() variable) — it's
// needed up front to build the ['messages', address] query key invalidated
// below, mirroring how useMessages(address) itself takes it. key is still
// passed into mutate() since it identifies the specific message being
// deleted, not the mailbox the hook is scoped to.
export function useDeleteMessage(address: string) {
  const session = useSession();
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (key: string) => deleteMessage(session, address, key),
    // Unlike reply, there IS a list view (Inbox.tsx) showing the deleted
    // message — invalidate its query so the row disappears on success
    // instead of requiring a manual refresh.
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['messages', address] });
    },
  });
}
