# Use an official OCaml image based on Alpine Linux
FROM docker.io/ocaml/opam:alpine-3.20-ocaml-4.14

# Set up working directory
WORKDIR /workspace

# Update Alpine packages and install required dependencies
RUN sudo apk update && sudo apk add --no-cache \
    build-base \
    m4 \
    dune \
    gmp-dev \
    opam \
    bash \
    git \
    git-lfs 
    
# Initialize opam and install OCaml dependencies
RUN opam init --disable-sandboxing --auto-setup && \
    opam install dune

# Copy the project into the container
COPY . .

CMD ["bash"]
