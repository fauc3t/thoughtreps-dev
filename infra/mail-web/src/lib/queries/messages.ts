import { ListObjectsV2Command, type _Object } from '@aws-sdk/client-s3';
import { useQuery } from '@tanstack/react-query';
import { inboxPrefix } from '@thoughtreps/infra/mail/inbox';
import { MAIL_BUCKET_NAME } from '../config';
import { getS3Client } from '../s3Client';
import { useSession } from '../session';

// S3 object keys aren't reliably chronologically sortable (they're
// timestamp-prefixed by convention, not guaranteed) — sort by the actual
// LastModified timestamp instead of the key string.
function byNewestFirst(a: _Object, b: _Object): number {
  return (b.LastModified?.getTime() ?? 0) - (a.LastModified?.getTime() ?? 0);
}

export function useMessages(address: string) {
  const session = useSession();

  return useQuery({
    queryKey: ['messages', address],
    queryFn: async () => {
      const client = getS3Client(session);
      const res = await client.send(
        new ListObjectsV2Command({
          Bucket: MAIL_BUCKET_NAME,
          Prefix: inboxPrefix(address),
        }),
      );
      return [...(res.Contents ?? [])].sort(byNewestFirst);
    },
  });
}
