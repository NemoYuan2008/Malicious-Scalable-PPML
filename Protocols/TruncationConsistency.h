#ifndef PROTOCOLS_TRUNCATIONCONSISTENCY_H_
#define PROTOCOLS_TRUNCATIONCONSISTENCY_H_

#include <cstdint>

#include "Math/Mersenne.h"
#include "Tools/Commit.h"
#include "Tools/Exceptions.h"
#include "Tools/Hash.h"
#include "Tools/random.h"

namespace TruncationConsistency
{

template<class Field>
struct FieldSampling
{
    static bool canonical(const Field&) { return true; }

    static Field sample(PRNG& G)
    {
        Field value;
        value.randomize(G);
        return value;
    }
};

template<int L>
struct FieldSampling<Mersenne<L>>
{
    using Field = Mersenne<L>;

    static bool canonical(const Field& value)
    {
        return value.get() < Field::prime;
    }

    static Field sample(PRNG& G)
    {
        Field value;
        // Mersenne::randomize also samples the all-one encoding p. Reject
        // it here, rather than introducing bias by mapping it to zero.
        do
            value.randomize(G);
        while (not canonical(value));
        return value;
    }
};

// All traffic is local to this check: unchecked_broadcast accounts for the
// communication but does not add to, or flush, Player's delayed transcript.
inline void accept_or_abort(const Player& P, const octetStream& context,
        int phase, bool accept)
{
    vector<octetStream> statuses(P.num_players());
    auto expected = context;
    expected.store(phase);
    expected.store(1);
    statuses[P.my_num()] = context;
    statuses[P.my_num()].store(phase);
    statuses[P.my_num()].store(int(accept));
    P.unchecked_broadcast(statuses);
    for (const auto& status : statuses)
        accept &= status == expected;
    if (not accept)
        throw mac_fail("Atlas: truncation opening consistency failed (phase "
                + to_string(phase) + ")");
}

template<class Field>
void check(const vector<Field>& values, size_t expected_count,
        uint64_t batch, const Player& P)
{
    if (expected_count == 0)
    {
        if (not values.empty())
            throw mac_fail("Atlas: unexpected openings in empty truncation batch");
        return;
    }

    bool valid = values.size() == expected_count;
    for (const auto& value : values)
        valid &= FieldSampling<Field>::canonical(value);

    octetStream context;
    context.store(string("Atlas truncation consistency v1"));
    context.store(static_cast<unsigned long long>(batch));
    context.store(expected_count);

    // The opening vector is fixed before any coin contribution is revealed.
    // At least one honest contribution is uniform and hidden until opening.
    SeededPRNG G;
    auto contribution = FieldSampling<Field>::sample(G);
    auto message = context;
    contribution.pack(message);
    vector<octetStream> commitments(P.num_players()), openings(P.num_players());
    Commit(commitments[P.my_num()], openings[P.my_num()], message, P.my_num());
    const auto commitment_size = commitments[P.my_num()].get_length();
    const auto opening_size = openings[P.my_num()].get_length();
    P.unchecked_broadcast(commitments);
    P.unchecked_broadcast(openings);

    Field challenge(0);
    Hash transcript;
    transcript.update(context);
    for (int i = 0; i < P.num_players(); ++i)
    {
        // Length-prefix the transcript, including malformed packets. Check
        // lengths before Open(), whose decoder assumes a complete packet.
        octetStream lengths;
        lengths.store(commitments[i].get_length());
        lengths.store(openings[i].get_length());
        transcript.update(lengths);
        transcript.update(commitments[i]);
        transcript.update(openings[i]);

        octetStream decoded;
        if (commitments[i].get_length() != commitment_size
                or openings[i].get_length() != opening_size
                or not Open(decoded, commitments[i], openings[i], i))
        {
            valid = false;
            continue;
        }
        if (decoded.get_length() != message.get_length()
                or memcmp(decoded.consume(context.get_length()),
                        context.get_data(), context.get_length()) != 0)
        {
            valid = false;
            continue;
        }
        Field part;
        part.unpack(decoded);
        if (not decoded.done() or not FieldSampling<Field>::canonical(part))
        {
            valid = false;
            continue;
        }
        challenge += part;
    }

    // Establish a common coin transcript now, not at the final output check.
    // These hashes check the coin only; the openings use the field fingerprint.
    auto digest = transcript.final();
    vector<octetStream> digests(P.num_players());
    digests[P.my_num()] = digest;
    P.unchecked_broadcast(digests);
    for (const auto& other : digests)
        valid &= other == digest;
    accept_or_abort(P, context, 0, valid);

    // Horner evaluation gives e_1 + e_2*r + ... + e_m*r^(m-1), including r=0.
    Field fingerprint(0);
    for (auto it = values.rbegin(); it != values.rend(); ++it)
        fingerprint = fingerprint * challenge + *it;

    vector<octetStream> fingerprints(P.num_players());
    auto expected = context;
    fingerprint.pack(expected);
    fingerprints[P.my_num()] = expected;
    P.unchecked_broadcast(fingerprints);
    for (const auto& other : fingerprints)
        valid &= other == expected;
    accept_or_abort(P, context, 1, valid);
}

}

#endif /* PROTOCOLS_TRUNCATIONCONSISTENCY_H_ */
