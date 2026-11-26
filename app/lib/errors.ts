import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from "viem";
import { chain } from "./config";

const MESSAGES: Record<string, string> = {
  ZeroAddress: "An address is missing.",
  SelfDeal: "You cannot hire yourself.",
  AmountTooSmall: "The minimum is 0.5 QUSDC.",
  AmountTooLarge: "That amount is too large.",
  BadDeadlines: "Check the dates: accept-by must be in the future and before deliver-by.",
  BadReviewWindow: "The review window must be between 1 hour and 7 days.",
  BriefTooLong: "The brief is too long (max 500 characters).",
  BadUrl: "The post link is not valid.",
  PostAlreadyUsed: "You already used this post in another campaign.",
  NotSponsor: "Only the sponsor of this campaign can do that.",
  NotCreator: "Only the creator of this campaign can do that.",
  WrongStatus: "The campaign is not in the right state for this. Refresh the page.",
  TooLate: "The deadline for this step has passed.",
  TooEarly: "The review window is still open.",
  NotExpired: "The deadline has not passed yet.",
  SwapShort: "The QIEDEX swap returned too little QUSDC. Try again.",
  RefundFailed: "The leftover QIE could not be returned to your wallet.",
  NotNameOwner: "Your wallet does not own that .qie name.",
  BadLabel: "That .qie name is too long.",
  EXCESSIVE_INPUT_AMOUNT: "The QIE price moved. Try again.",
};

export function readableError(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "You rejected the request in your wallet.";
    const revert = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName ?? revert.reason ?? "";
      for (const k of Object.keys(MESSAGES)) if (name.includes(k)) return MESSAGES[k];
      if (name.includes("ERC20InsufficientBalance") || name.includes("ERC20InsufficientAllowance"))
        return "Not enough QUSDC, or the approval is too small.";
      return name || "The transaction was reverted.";
    }
    if (/insufficient funds/i.test(e.message)) return "Not enough QIE in your wallet to pay for gas.";
    if (/chain mismatch|does not match the target chain|switch chain|unrecognized chain/i.test(e.message))
      return `Your wallet is on another network. Switch it to ${chain.name} and try again.`;
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}
