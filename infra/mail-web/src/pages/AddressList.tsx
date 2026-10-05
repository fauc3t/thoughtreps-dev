import { Link } from 'react-router-dom';
import { MAILBOX_ADDRESSES } from '../lib/config';

export default function AddressList() {
  return (
    <div className="mx-auto max-w-xl p-6">
      <h1 className="mb-4 text-xl font-semibold">Mailboxes</h1>
      <ul className="divide-y divide-gray-200 rounded-lg border border-gray-200">
        {MAILBOX_ADDRESSES.map((address) => (
          <li key={address}>
            <Link
              to={`/${encodeURIComponent(address)}`}
              className="block px-4 py-3 hover:bg-gray-50"
            >
              {address}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
