import { DurableObject } from 'cloudflare:workers';
import worker, { FeedbackInbox as InboxLogic } from './worker.mjs';

export default worker;

export class FeedbackInbox extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.logic = new InboxLogic(ctx, env);
  }

  fetch(request) { return this.logic.fetch(request); }
}
