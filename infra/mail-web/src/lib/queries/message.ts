import { GetObjectCommand } from '@aws-sdk/client-s3';
import { useQuery } from '@tanstack/react-query';
import PostalMime from 'postal-mime';
import { MAIL_BUCKET_NAME } from '../config';
import { getS3Client } from '../s3Client';
import { useSession } from '../session';

export function useMessage(key: string) {
  const session = useSession();

  return useQuery({
    queryKey: ['message', key],
    queryFn: async () => {
      const client = getS3Client(session);
      const res = await client.send(
        new GetObjectCommand({ Bucket: MAIL_BUCKET_NAME, Key: key }),
      );
      if (!res.Body) {
        throw new Error(`Object has no body (${key})`);
      }
      const bytes = await res.Body.transformToByteArray();
      return PostalMime.parse(bytes);
    },
  });
}
