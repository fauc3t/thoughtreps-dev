import { useMutation } from '@tanstack/react-query';
import { replyToMessage } from '../api';
import { useSession } from '../session';

interface ReplyVariables {
  address: string;
  key: string;
  body: string;
}

// No cache invalidation on success — unlike a typical mutation hook, there's
// no reply-list view anywhere in this app for a sent reply to show up in, so
// there's nothing to invalidate. The page consumes mutate/isPending/
// isError/isSuccess/error directly to drive its own inline UI state.
export function useReply() {
  const session = useSession();

  return useMutation({
    mutationFn: ({ address, key, body }: ReplyVariables) =>
      replyToMessage(session, address, key, body),
  });
}
