require "sinatra"
require "socket"
require "json"
require "pry"
require "openssl"
require "base64"
require "net/http"

Tilt.register Tilt::ERBTemplate, 'html.erb'

class Wallet
  attr_reader :key_pair

  def initialize(wallet_path = "#{ENV["HOME"]}/.wallet.der")
    @key_pair = load_or_generate_wallet(wallet_path)
  end

  def load_or_generate_wallet(path)
    if File.exists?(path)
      OpenSSL::PKey.read(Base64.decode64(File.read(path)))
    else
      key_pair = OpenSSL::PKey::RSA.generate(2048)
      File.write(path, Base64.encode64(key_pair.to_der).gsub("\n", ""))
      key_pair
    end
  end

  def public_key
    key_pair.public_key
  end

  def sign_transaction(txn)
    signable_input_strings = txn["inputs"].map { |i| i["source-hash"] + i["source-index"].to_s }
    signable_output_strings = txn["outputs"].map { |i| i["amount"].to_s + i["address"].to_s }
    signature = sign((signable_input_strings + signable_output_strings).join("")).delete("\n")

    txn.dup.tap do |t|
      t["inputs"].each do |i|
        i["signature"] = signature
      end
    end
  end

  def sign(string)
    Base64.encode64(key_pair.sign(OpenSSL::Digest::SHA256.new, string))
  end

  def address
    Base64.encode64(public_key.to_der).gsub("\n", "")
  end
end


class ClarkeClient
  attr_reader :host, :port
  def initialize(host = "localhost", port = 3000)
    @host = host
    @port = port
  end


  def post(path, data)
    uri = URI("http://#{host}:#{port}#{path}")

    Net::HTTP.start(uri.host, uri.port) do |http|
      request = Net::HTTP::Post.new uri
      request.set_content_type("application/json")
      request.body = data.to_json

      response = http.request request
      JSON.parse(response.body)
    end
  end

  def get(path)
    uri = URI("http://#{host}:#{port}#{path}")
    JSON.parse(Net::HTTP.get(uri))
  end

  def send_message(type, payload = {})
    s = TCPSocket.new(host,port)
    message = {"message_type" => type, "payload" => payload}
    s.write(message.to_json + "\n\n")
    resp = JSON.parse(s.read)
    s.close
    resp
  end

  def echo(payload)
    post("/echo", payload)
  end

  def get_blocks
    get("/blocks")
  end

  def get_block(hash)
    get("/blocks/#{hash}")
  end

  def get_transaction(hash)
    get("/transactions/#{hash}")
  end

  def get_balance(address)
    post("/balance", {address: address})
  end

  def generate_payment(from_key, to_key, amount)
    payload = {from_address: from_key, to_address: to_key, amount: amount, fee: 1}
    post("/unsigned_payment_transactions", payload)
  end

  def submit_transaction(txn)
    post("/pending_transactions", txn)
  end
end

client = ClarkeClient.new
wallet = Wallet.new

def splits(blocks)
  blocks.map { |b| b["header"]["timestamp"].to_i / 1000 }.each_cons(2).map { |a,b| a - b }
end

get "/" do
  @blocks = client.get_blocks["payload"].reverse
  @splits = splits(@blocks)
  erb :"blocks/index"
end

get "/blocks/:hash" do
  @block = client.get_block(params[:hash])["payload"]
  erb :"blocks/show"
end

get "/transactions/:hash" do
  @txn = client.get_transaction(params[:hash])["payload"]
  erb :"transactions/show"
end

post "/balances" do
  @balance_info = client.get_balance(params[:address].gsub("\r\n","\n"))["payload"]
  erb :"balances/create"
end

get "/transactions/pool" do
  # show current txn pool
end

get "/payments/new" do
  @address = wallet.address
  erb :"payments/new"
end

post "/payments" do
  amount = params[:amount].to_i
  address = params[:address]
  if amount <= 0
    "Sorry, #{params[:amount]} is not valid."
  else
    unsigned = client.generate_payment(wallet.address, params[:address], amount)
    puts "RECEIVED UNSIGNED PAYMENT: #{unsigned}"
    signed = wallet.sign_transaction(unsigned["payload"])
    resp = client.submit_transaction(signed)
    content_type :json
    resp.to_json
  end
end

get "/balance" do
  @balance_info = client.get_balance(wallet.public_pem)["payload"]
  erb :"balances/create"
end
