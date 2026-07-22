// Stub implementation of util/read_compressed.cc for iOS query-only use.
// These functions are only called when loading ARPA or compressed model files.
// For binary (.klm) model loading, they are never exercised.
// See third-party/kenlm/README.md for details.
#include "read_compressed.hh"

namespace util {

// All exceptions derive from Exception, which is defined in exception.cc.
CompressedException::CompressedException() throw() : Exception() {}
CompressedException::~CompressedException() throw() {}

GZException::GZException() throw() : CompressedException() {}
GZException::~GZException() throw() {}

BZException::BZException() throw() : CompressedException() {}
BZException::~BZException() throw() {}

XZException::XZException() throw() : CompressedException() {}
XZException::~XZException() throw() {}

void ReadBase::ReplaceThis(ReadBase * /*with*/, ReadCompressed & /*thunk*/) {}
ReadBase *ReadBase::Current(ReadCompressed & /*thunk*/) { return NULL; }
uint64_t &ReadBase::ReadCount(ReadCompressed & /*thunk*/) { static uint64_t c = 0; return c; }

bool ReadCompressed::DetectCompressedMagic(const void * /*from*/) { return false; }

ReadCompressed::ReadCompressed(int /*fd*/) : raw_amount_(0) {}
ReadCompressed::ReadCompressed(std::istream & /*in*/) : raw_amount_(0) {}
ReadCompressed::ReadCompressed() : raw_amount_(0) {}

void ReadCompressed::Reset(int /*fd*/) {}
void ReadCompressed::Reset(std::istream & /*in*/) {}

std::size_t ReadCompressed::Read(void * /*to*/, std::size_t /*amount*/) { return 0; }
std::size_t ReadCompressed::ReadOrEOF(void * /*to*/, std::size_t /*amount*/) { return 0; }

} // namespace util
