import { useState } from 'react';
import { useMutation } from '@tanstack/react-query';
import {
  replyToMessage,
  requestAttachmentUpload,
  uploadAttachment,
} from '../api';
import type { ReplyAttachment } from '../api';
import { useSession } from '../session';

interface ReplyVariables {
  address: string;
  key: string;
  body: string;
  files: File[];
}

export type ReplyPhase = 'uploading' | 'sending' | null;

// No cache invalidation on success — unlike a typical mutation hook, there's
// no reply-list view anywhere in this app for a sent reply to show up in, so
// there's nothing to invalidate. The page consumes mutate/isPending/
// isError/isSuccess/error directly to drive its own inline UI state.
//
// The whole send (upload each file, then reply) is one mutation; `phase`
// tells the page which step is running while isPending is true, for the
// button label.
export function useReply() {
  const session = useSession();
  const [phase, setPhase] = useState<ReplyPhase>(null);

  const mutation = useMutation({
    mutationFn: async ({ address, key, body, files }: ReplyVariables) => {
      try {
        const attachments: ReplyAttachment[] = [];
        if (files.length > 0) setPhase('uploading');
        for (const file of files) {
          const post = await requestAttachmentUpload(session, address, file);
          await uploadAttachment(post, file);
          attachments.push({
            key: post.key,
            filename: file.name,
            contentType: file.type || 'application/octet-stream',
          });
        }
        setPhase('sending');
        return await replyToMessage(
          session,
          address,
          key,
          body,
          attachments.length > 0 ? attachments : undefined,
        );
      } finally {
        setPhase(null);
      }
    },
  });

  return { ...mutation, phase };
}
