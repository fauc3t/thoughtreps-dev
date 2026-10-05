import { useEffect, useMemo } from 'react';
import type { Attachment } from 'postal-mime';
import {
  attachmentByteLength,
  attachmentToBlob,
  downloadableAttachments,
  formatAttachmentSize,
} from '../lib/attachments';

export default function AttachmentList({
  attachments,
}: {
  attachments: Attachment[];
}) {
  // One object URL per attachment, built once per `attachments` array
  // reference (a fresh one only on a new message load) rather than on every
  // render — createObjectURL/revokeObjectURL churn on each render would
  // needlessly recreate blobs for content that never actually changed.
  const items = useMemo(
    () =>
      downloadableAttachments(attachments).map((attachment) => ({
        attachment,
        url: URL.createObjectURL(attachmentToBlob(attachment)),
      })),
    [attachments],
  );

  useEffect(() => {
    return () => {
      items.forEach(({ url }) => URL.revokeObjectURL(url));
    };
  }, [items]);

  if (items.length === 0) return null;

  return (
    <section className="mt-4 border-t border-gray-200 pt-4">
      <h2 className="mb-2 text-sm font-medium text-gray-700">
        Attachments ({items.length})
      </h2>
      <ul className="flex flex-col gap-1">
        {items.map(({ attachment, url }, index) => (
          <li key={index}>
            <a
              href={url}
              download={attachment.filename ?? 'attachment'}
              className="flex flex-wrap items-baseline gap-2 rounded border border-gray-200 px-3 py-2 text-sm text-blue-600 hover:bg-gray-50"
            >
              <span className="font-medium">
                {attachment.filename ?? '(unnamed attachment)'}
              </span>
              <span className="text-gray-400">
                {attachment.mimeType} ·{' '}
                {formatAttachmentSize(attachmentByteLength(attachment))}
              </span>
            </a>
          </li>
        ))}
      </ul>
    </section>
  );
}
