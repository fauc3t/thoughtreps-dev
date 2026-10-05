import { useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import type { Address } from 'postal-mime';
import { useMessage } from '../lib/queries/message';
import { useReply } from '../lib/queries/reply';
import { useDeleteMessage } from '../lib/queries/delete';
import AttachmentList from '../components/AttachmentList';

function formatAddress(address: Address | undefined): string {
  if (!address) return '(unknown sender)';
  if (address.group) {
    return address.group.map((m) => m.address).join(', ');
  }
  if (address.name) return `${address.name} <${address.address}>`;
  return address.address ?? '(unknown sender)';
}

export default function Message() {
  const { address, key } = useParams<{ address: string; key: string }>();
  const navigate = useNavigate();
  const query = useMessage(key ?? '');
  const reply = useReply();
  const deleteMessage = useDeleteMessage(address ?? '');
  const [replyBody, setReplyBody] = useState('');

  if (!address || !key) return null;

  function handleSendReply() {
    if (!address || !key || !replyBody.trim()) return;
    reply.mutate(
      { address, key, body: replyBody },
      { onSuccess: () => setReplyBody('') },
    );
  }

  function handleDelete() {
    if (!address || !key) return;
    if (!window.confirm('Delete this message?')) return;
    // Unlike Inbox.tsx's row delete (where staying on the list is correct),
    // the message this page is displaying no longer exists once the delete
    // succeeds — navigate back to the inbox list rather than leaving the
    // user on a page showing a now-deleted message.
    deleteMessage.mutate(key, {
      onSuccess: () => navigate(`/${encodeURIComponent(address)}`),
    });
  }

  return (
    <div className="mx-auto max-w-3xl p-6">
      <p className="mb-1 text-sm text-gray-500">
        <Link to={`/${encodeURIComponent(address)}`}>{address}</Link>
      </p>

      {query.isLoading && <p>Loading…</p>}
      {query.isError && (
        <p role="alert" className="text-red-600">
          Failed to load message.
        </p>
      )}
      {query.data && (
        <article>
          <div className="mb-2 flex items-start justify-between gap-4">
            <h1 className="text-xl font-semibold">
              {query.data.subject ?? '(no subject)'}
            </h1>
            <button
              type="button"
              onClick={handleDelete}
              disabled={deleteMessage.isPending}
              className="shrink-0 rounded border border-red-300 px-3 py-1.5 text-sm font-medium text-red-600 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {deleteMessage.isPending ? 'Deleting…' : 'Delete'}
            </button>
          </div>
          {deleteMessage.isError && (
            <p role="alert" className="mb-2 text-sm text-red-600">
              {deleteMessage.error.message}
            </p>
          )}
          <dl className="mb-4 text-sm text-gray-600">
            <div className="flex gap-2">
              <dt className="font-medium">From:</dt>
              <dd>{formatAddress(query.data.from)}</dd>
            </div>
            {query.data.date && (
              <div className="flex gap-2">
                <dt className="font-medium">Date:</dt>
                <dd>{new Date(query.data.date).toLocaleString()}</dd>
              </div>
            )}
          </dl>
          {/* Message HTML comes from an untrusted third-party email — an
              iframe with no allow-scripts in its sandbox renders it without
              executing scripts or leaking its styles into the parent page,
              rather than dangerouslySetInnerHTML directly into this tree. */}
          {query.data.html ? (
            <iframe
              title="Message body"
              sandbox=""
              srcDoc={query.data.html}
              className="h-[60vh] w-full rounded border border-gray-200"
            />
          ) : (
            <pre className="whitespace-pre-wrap font-sans">
              {query.data.text ?? '(empty message)'}
            </pre>
          )}

          <AttachmentList attachments={query.data.attachments} />

          <section className="mt-6 border-t border-gray-200 pt-4">
            <h2 className="mb-2 text-sm font-medium text-gray-700">Reply</h2>
            <textarea
              value={replyBody}
              onChange={(e) => setReplyBody(e.target.value)}
              placeholder="Type your reply…"
              rows={6}
              className="w-full rounded border border-gray-300 p-2 text-sm"
            />
            <div className="mt-2 flex items-center gap-3">
              <button
                type="button"
                onClick={handleSendReply}
                disabled={reply.isPending || !replyBody.trim()}
                className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:opacity-50"
              >
                {reply.isPending ? 'Sending…' : 'Send reply'}
              </button>
              {reply.isSuccess && (
                <p className="text-sm text-green-600">Reply sent</p>
              )}
              {reply.isError && (
                <p role="alert" className="text-sm text-red-600">
                  {reply.error.message}
                </p>
              )}
            </div>
          </section>
        </article>
      )}
    </div>
  );
}
