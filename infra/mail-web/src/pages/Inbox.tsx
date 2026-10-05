import { Link, useParams } from 'react-router-dom';
import { useMessage } from '../lib/queries/message';
import { useMessages } from '../lib/queries/messages';
import { useDeleteMessage } from '../lib/queries/delete';

// The key rendered per row is the S3 object's full key (address/inbox/...),
// not just its filename tail — Message.tsx's GetObjectCommand needs the
// full key, and encodeURIComponent below turns its embedded "/" into a
// single opaque path segment for the :key route param (react-router
// decodes it back automatically on the read side via useParams).
function filenameFromKey(key: string): string {
  return key.split('/').pop() ?? key;
}

// A separate component per row (not read inline in the list map) so each
// row's useMessage call is its own hook instance — React Query then fetches
// every row's subject in parallel and caches each one by key. That cache is
// shared with Message.tsx's own useMessage(key) call, so clicking into a
// message the list has already rendered a subject for is an instant cache
// hit, not a second fetch.
function MessageRow({
  address,
  objectKey,
  lastModified,
}: {
  address: string;
  objectKey: string;
  lastModified: Date | undefined;
}) {
  const query = useMessage(objectKey);
  const deleteMessage = useDeleteMessage(address);
  // While loading or on a per-message parse/fetch failure, fall back to the
  // filename (the S3 message id) rather than blocking the whole row — a
  // missing subject on one message shouldn't stop the rest of the inbox
  // from being usable.
  const label =
    query.isSuccess && query.data.subject?.trim()
      ? query.data.subject.trim()
      : query.isSuccess
        ? '(no subject)'
        : filenameFromKey(objectKey);

  function handleDelete() {
    if (!window.confirm('Delete this message?')) return;
    deleteMessage.mutate(objectKey);
  }

  return (
    <div className="flex items-center justify-between gap-4 px-4 py-3 hover:bg-gray-50">
      {/* A <button> can't nest inside this row's own <Link> (invalid,
          interactive-in-interactive HTML), so the row is a plain <div> with
          the Link scoped to just the label/timestamp and Delete a sibling
          button, rather than the whole row being clickable. */}
      <Link
        to={`/${encodeURIComponent(address)}/${encodeURIComponent(objectKey)}`}
        className="flex min-w-0 flex-1 items-center justify-between gap-4"
      >
        <span className="truncate">{label}</span>
        <span className="shrink-0 text-sm text-gray-500">
          {lastModified?.toLocaleString() ?? ''}
        </span>
      </Link>
      <button
        type="button"
        onClick={handleDelete}
        disabled={deleteMessage.isPending}
        className="shrink-0 rounded px-2 py-1 text-sm text-red-600 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50"
      >
        {deleteMessage.isPending ? 'Deleting…' : 'Delete'}
      </button>
    </div>
  );
}

export default function Inbox() {
  const { address } = useParams<{ address: string }>();
  const query = useMessages(address ?? '');

  if (!address) return null;

  return (
    <div className="mx-auto max-w-2xl p-6">
      <p className="mb-1 text-sm text-gray-500">
        <Link to="/">Mailboxes</Link>
      </p>
      <h1 className="mb-4 text-xl font-semibold">{address}</h1>

      {query.isLoading && <p>Loading…</p>}
      {query.isError && (
        <p role="alert" className="text-red-600">
          Failed to load messages.
        </p>
      )}
      {query.data && query.data.length === 0 && (
        <p className="text-gray-500">No messages yet.</p>
      )}
      {query.data && query.data.length > 0 && (
        <ul className="divide-y divide-gray-200 rounded-lg border border-gray-200">
          {query.data.map((object) => {
            const key = object.Key;
            if (!key) return null;
            return (
              <li key={key}>
                <MessageRow
                  address={address}
                  objectKey={key}
                  lastModified={object.LastModified}
                />
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
