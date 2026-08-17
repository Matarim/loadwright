# frozen_string_literal: true

RSpec.describe Loadwright::Execution::Request do
  describe "the correlation id" do
    # Generated here rather than in the transport, because the collector needs it
    # BEFORE the request is issued — the whole point of subscribing once and
    # routing per event is that the bucket exists first.
    it "is generated per request and is unique" do
      ids = 100.times.map { build_request.request_id }

      expect(ids.uniq.length).to eq(100)
      expect(ids.first).to start_with("lw-")
    end

    it "can be supplied, for replaying a recorded request" do
      expect(build_request(request_id: "fixed-id").request_id).to eq("fixed-id")
    end
  end

  describe "#full_path" do
    # Assembled here rather than in each transport, so :in_process and :http
    # cannot disagree about what was requested. A divergence there would make the
    # two modes incomparable in a way no per-transport spec would catch.
    it "appends the query string" do
      expect(build_request(path: "/posts", query: { per_page: 25, page: 2 }).full_path)
        .to eq("/posts?per_page=25&page=2")
    end

    it "leaves a path with no query alone" do
      expect(build_request(path: "/posts").full_path).to eq("/posts")
    end

    it "uses & when the path already carries a query string" do
      expect(build_request(path: "/posts?draft=1", query: { per_page: 5 }).full_path)
        .to eq("/posts?draft=1&per_page=5")
    end

    it "escapes values" do
      expect(build_request(path: "/search", query: { q: "a b&c" }).full_path).to eq("/search?q=a+b%26c")
    end
  end

  describe "#mutating?" do
    # allow_mutating_requests defaults to false, so this classification is what
    # decides whether an endpoint is exercised at all. GET/HEAD/OPTIONS are the
    # allowlist, not "anything that isn't DELETE".
    %i[get head options].each do |verb|
      it "treats #{verb.upcase} as safe" do
        expect(build_request(verb: verb)).not_to be_mutating
      end
    end

    %i[post put patch delete].each do |verb|
      it "treats #{verb.upcase} as mutating" do
        expect(build_request(verb: verb)).to be_mutating
      end
    end

    it "treats an unrecognised verb as mutating, which is the fail-closed answer" do
      expect(build_request(verb: :purge)).to be_mutating
    end
  end

  it "normalises the verb, so 'GET' and :get are the same request" do
    expect(build_request(verb: "GET").verb).to eq(:get)
  end

  it "keys itself by verb and path template for the discovery merge" do
    expect(build_request(verb: :post, path: "/posts/{id}/comments").endpoint_key)
      .to eq("POST /posts/{id}/comments")
  end

  it "is frozen, so a request cannot be mutated between cells of the matrix" do
    expect(build_request).to be_frozen
  end
end
