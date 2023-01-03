import Client from "mina-signer";
import {
  Field,
  declareState,
  declareMethods,
  State,
  PrivateKey,
  SmartContract,
  deploy,
  isReady,
  shutdown,
  addCachedAccount,
  Mina,
  verify,
} from "snarkyjs";

await isReady;
const zkappTargetBalance = 10_000_000_000;
const initialBalance = zkappTargetBalance;
const transactionFee = 10_000_000;
const initialState = Field(1);

class SimpleZkapp extends SmartContract {
  constructor(address) {
    super(address);
    this.x = State();
  }

  deploy(args) {
    super.deploy(args);
    this.x.set(initialState);
  }

  update(y) {
    let x = this.x.get();
    this.x.assertEquals(x);
    y.assertGt(0);
    this.x.set(x.add(y));
  }
}
declareState(SimpleZkapp, { x: Field });
declareMethods(SimpleZkapp, { update: [Field] });

let [graphql] = process.argv.slice(2);

console.log(
  `simple-zkapp.js: Running "${command}" with zkapp key ${zkappKeyBase58}, fee payer key ${feePayerKeyBase58} and fee payer nonce ${feePayerNonce}`
);

let Berkeley = Mina.Network(graphql);
Mina.setActiveInstance(Berkeley);

let senderKey = PrivateKey.random();
let sender = senderKey.toPublicKey();

let { nonce, balance } = Berkeley.getAccount(sender);
console.log(
  `Using fee payer ${sender.toBase58()} with nonce ${nonce}, balance ${balance}`
);

console.log("Compiling smart contract..");
let { verificationKey } = await HelloWorld.compile();

let zkapp = new HelloWorld(zkappAddress);

console.log(`Deploying zkapp for public key ${zkappAddress.toBase58()}.`);

let transaction = await Mina.transaction(
  { sender, fee: transactionFee },
  () => {
    AccountUpdate.fundNewAccount(sender);
    zkapp.deploy({ verificationKey });
  }
);
transaction.sign([senderKey, zkappKey]);

console.log("Sending the transaction..");
await (await transaction.send()).wait();

console.log("Fetching updated accounts..");
await fetchAccount({ publicKey: senderKey.toPublicKey() });
await fetchAccount({ publicKey: zkappAddress });

console.log("Trying to update deployed zkApp..");

transaction = await Mina.transaction({ sender, fee: transactionFee }, () => {
  zkapp.update(Field(4), adminPrivateKey);
});
await transaction.sign([senderKey]).prove();

console.log("Sending the transaction..");
await (await transaction.send()).wait();

console.log("Checking if the update was valid..");

try {
  (await zkapp.x.fetch())?.assertEquals(Field(4));
} catch (error) {
  throw new Error(
    `On-chain zkApp account doesn't match the expected state. ${error}`
  );
}
console.log("Success!");

shutdown();
