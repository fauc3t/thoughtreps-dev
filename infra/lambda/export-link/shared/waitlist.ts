import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import {
  PutCommand,
  UpdateCommand,
  type DynamoDBDocumentClient,
} from '@aws-sdk/lib-dynamodb';

export interface Waitlist {
  // True if the email is new. An existing email keeps its row, except that
  // beta is upgraded to true when requested.
  signUp(email: string, beta: boolean, createdAt: string): Promise<boolean>;
}

export class DynamoWaitlist implements Waitlist {
  constructor(
    private readonly db: DynamoDBDocumentClient,
    private readonly tableName: string,
  ) {}

  async signUp(email: string, beta: boolean, createdAt: string) {
    try {
      await this.db.send(
        new PutCommand({
          TableName: this.tableName,
          Item: { email, beta, createdAt },
          ConditionExpression: 'attribute_not_exists(email)',
        }),
      );
      return true;
    } catch (err) {
      if (!(err instanceof ConditionalCheckFailedException)) throw err;
    }
    if (beta) {
      await this.db.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { email },
          UpdateExpression: 'SET beta = :true',
          ConditionExpression: 'attribute_exists(email)',
          ExpressionAttributeValues: { ':true': true },
        }),
      );
    }
    return false;
  }
}
